// PsychMetal keyboard queue. SPDX-License-Identifier: MIT
//
// A worker polls the keyboard state and records each change with the time of the
// scan that found it. A source of key events with times of their own (the
// engine's event tap) can post them here instead: post() records the change with
// the event's time, and polling becomes the safety net. Once events have been
// seen, a change that polling finds is given `grace` seconds for its event to
// arrive; only if none does is it recorded, with the time polling first saw it.
// A change that reverts inside the grace with no event for that key is recorded
// too, both ways, and late events for it are then ignored. Until an event has
// been seen there is no grace, so a source that delivers nothing leaves the queue
// exactly as it was when it only polled. Flush is a barrier for both sources:
// nothing that happened before it is recorded after it.
#ifndef PSYCHMETAL_KEYBOARD_QUEUE_H
#define PSYCHMETAL_KEYBOARD_QUEUE_H
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>
struct PMKeyEvent { double time; int key; bool pressed; };
class PMKeyboardQueue {
public:
    using Reader=void (*)(bool*,const bool*);
    using Clock=double (*)();
    static constexpr unsigned capacity=4096;
    struct Stats { bool created,running; double interval,lastScanInterval,maxScanInterval; unsigned long long scans,dropped;
                   bool events; unsigned long long eventStamped,pollStamped; double maxEventDelay; };
    static constexpr double grace=.020;
    PMKeyboardQueue(Reader r,Clock c):read(r),clock(c) {}
    ~PMKeyboardQueue() { release(); }
    void create(const bool* filter,double seconds) {
        stop(); std::lock_guard<std::mutex> guard(mutex);
        std::memcpy(mask,filter,sizeof(mask)); interval=seconds; created=true; clearLocked();
    }
    bool exists() { std::lock_guard<std::mutex> guard(mutex); return created; }
    bool isRunning() { std::lock_guard<std::mutex> guard(mutex); return running; }
    bool start() {
        if(!exists()) return false;
        if(isRunning()) return true;
        bool baseline[256]={}; read(baseline,mask);
        std::lock_guard<std::mutex> guard(mutex);
        clearLocked(); std::memcpy(previous,baseline,sizeof(previous));
        stopping=false; running=true; scans=0; lastStamp=lastScanInterval=maxScanInterval=0;
        external=eventsSeen=false; eventStamped=pollStamped=0; maxEventDelay=0;
        try { thread=std::thread(&PMKeyboardQueue::loop,this); }
        catch(...) { running=false; return false; }
        return true;
    }
    void stop() {
        { std::lock_guard<std::mutex> guard(mutex); stopping=true; wake.notify_all(); }
        if(thread.joinable()) thread.join();
        std::lock_guard<std::mutex> guard(mutex); running=false; external=false;
    }
    // Key events with their own times will be posted (true), or no longer will be.
    void setExternal(bool on) { std::lock_guard<std::mutex> guard(mutex); external=on&&running; if(!external) eventsSeen=false; }
    // One key event: HID usage (1-based), pressed or released, at `stamp`; `delay` is how long it took to arrive.
    void post(double stamp,int usage,bool pressed,double delay) {
        std::lock_guard<std::mutex> guard(mutex);
        if(!running || !external || usage<1 || usage>256 || !mask[usage-1]) return;
        int k=usage-1; eventsSeen=true; pendingSince[k]=0; lastPost[k]=stamp+delay;
        if(stamp<=covered[k]) return;         // polling has recorded this key up to then
        if(previous[k]==pressed) return;      // polling recorded it already
        previous[k]=pressed;
        if(stamp<flushedAt) return;           // it happened before the flush
        recordLocked(stamp,k,pressed); ++eventStamped;
        if(delay>maxEventDelay) maxEventDelay=delay;
    }
    void release() { stop(); std::lock_guard<std::mutex> guard(mutex); created=false; clearLocked(); }
    void flush() { std::lock_guard<std::mutex> guard(mutex); ++generation; flushedAt=clock();
                   head=0; size=0; dropped=0; std::memset(summary,0,sizeof(summary)); }
    Stats stats() { std::lock_guard<std::mutex> guard(mutex); return {created,running,interval,lastScanInterval,maxScanInterval,scans,dropped,
                                                                      external,eventStamped,pollStamped,maxEventDelay}; }
    std::vector<PMKeyEvent> events(unsigned long long &lost) {
        std::vector<PMKeyEvent> out; out.reserve(capacity); // allocation outside lock
        std::lock_guard<std::mutex> guard(mutex);
        for(unsigned i=0;i<size;i++) out.push_back(buffer[(head+i)%capacity]);
        head=0; size=0; lost=dropped; return out;
    }
    void check(double out[4][256]) {
        std::lock_guard<std::mutex> guard(mutex); std::memcpy(out,summary,sizeof(summary));
        std::memset(summary,0,sizeof(summary));
    }
private:
    Reader read; Clock clock; std::thread thread; std::mutex mutex; std::condition_variable wake;
    bool created=false,running=false,stopping=false,mask[256]={},previous[256]={},external=false,eventsSeen=false;
    double interval=.002,summary[4][256]={},lastStamp=0,lastScanInterval=0,maxScanInterval=0,pendingSince[256]={},maxEventDelay=0,lastPost[256]={},covered[256]={},flushedAt=0;
    unsigned long long eventStamped=0,pollStamped=0;
    PMKeyEvent buffer[capacity]{};
    unsigned head=0,size=0; unsigned long long dropped=0,scans=0,generation=0;
    void clearLocked() { head=0; size=0; dropped=0; std::memset(summary,0,sizeof(summary)); std::memset(pendingSince,0,sizeof(pendingSince)); }
    void recordLocked(double stamp,int k,bool pressed) {
        int first=pressed?0:1,last=pressed?2:3;
        if(summary[first][k]==0) summary[first][k]=stamp;
        summary[last][k]=stamp;
        if(size==capacity) { head=(head+1)%capacity; --size; ++dropped; }
        buffer[(head+size)%capacity]={stamp,k+1,pressed}; ++size;
    }
    void loop() {
        using Steady=std::chrono::steady_clock;
        auto period=std::chrono::duration_cast<Steady::duration>(std::chrono::duration<double>(interval));
        auto deadline=Steady::now();
        std::unique_lock<std::mutex> guard(mutex);
        while(!stopping) {
            auto scanGeneration=generation;
            guard.unlock(); bool state[256]={}; read(state,mask); double stamp=clock(); guard.lock();
            if(stopping) break;
            if(lastStamp>0) { lastScanInterval=stamp-lastStamp; maxScanInterval=std::max(maxScanInterval,lastScanInterval); }
            lastStamp=stamp; ++scans;
            for(int k=0;k<256;k++) {
                if(!mask[k]) continue;
                if(state[k]==previous[k]) {
                    // Changed and changed back inside the grace. With an event for this key just
                    // posted the scan was only stale; with none, no event is coming and both are real.
                    if(pendingSince[k]!=0 && lastPost[k]<pendingSince[k]-grace) {
                        if(scanGeneration==generation && pendingSince[k]>=flushedAt) {
                            recordLocked(pendingSince[k],k,!previous[k]); recordLocked(stamp,k,previous[k]);
                            pollStamped+=2;
                        }
                        covered[k]=stamp;
                    }
                    pendingSince[k]=0; continue;
                }
                double seen=stamp;
                if(external && eventsSeen) {
                    // Give the key's own event time to arrive before recording this.
                    if(pendingSince[k]==0) pendingSince[k]=stamp;
                    if(stamp-pendingSince[k]<grace) continue;
                    seen=pendingSince[k]; pendingSince[k]=0;
                }
                previous[k]=state[k];
                // Flush is a barrier: discard a scan that overlapped it.
                if(scanGeneration!=generation || seen<flushedAt) continue;
                recordLocked(seen,k,state[k]); if(external) ++pollStamped;
            }
            deadline+=period;
            if(deadline<Steady::now()) deadline=Steady::now()+period;
            wake.wait_until(guard,deadline,[this]{return stopping;});
        }
    }
};
#endif
