// PsychMetal background-polled keyboard queue. SPDX-License-Identifier: MIT
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
    struct Stats { bool created,running; double interval,lastScanInterval,maxScanInterval; unsigned long long scans,dropped; };
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
        try { thread=std::thread(&PMKeyboardQueue::loop,this); }
        catch(...) { running=false; return false; }
        return true;
    }
    void stop() {
        { std::lock_guard<std::mutex> guard(mutex); stopping=true; wake.notify_all(); }
        if(thread.joinable()) thread.join();
        std::lock_guard<std::mutex> guard(mutex); running=false;
    }
    void release() { stop(); std::lock_guard<std::mutex> guard(mutex); created=false; clearLocked(); }
    void flush() { std::lock_guard<std::mutex> guard(mutex); ++generation; clearLocked(); }
    Stats stats() { std::lock_guard<std::mutex> guard(mutex); return {created,running,interval,lastScanInterval,maxScanInterval,scans,dropped}; }
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
    bool created=false,running=false,stopping=false,mask[256]={},previous[256]={};
    double interval=.002,summary[4][256]={},lastStamp=0,lastScanInterval=0,maxScanInterval=0;
    PMKeyEvent buffer[capacity]{};
    unsigned head=0,size=0; unsigned long long dropped=0,scans=0,generation=0;
    void clearLocked() { head=0; size=0; dropped=0; std::memset(summary,0,sizeof(summary)); }
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
                if(!mask[k] || state[k]==previous[k]) continue;
                previous[k]=state[k];
                // Flush is a barrier: discard a scan that overlapped it.
                if(scanGeneration!=generation) continue;
                int first=state[k]?0:1,last=state[k]?2:3;
                if(summary[first][k]==0) summary[first][k]=stamp;
                summary[last][k]=stamp;
                if(size==capacity) { head=(head+1)%capacity; --size; ++dropped; }
                buffer[(head+size)%capacity]={stamp,k+1,state[k]}; ++size;
            }
            deadline+=period;
            if(deadline<Steady::now()) deadline=Steady::now()+period;
            wake.wait_until(guard,deadline,[this]{return stopping;});
        }
    }
};
#endif
