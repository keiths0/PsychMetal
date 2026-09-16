// PsychMetal's bounded, background-polled keyboard queue. SPDX-License-Identifier: MIT
// No MEX or graphics calls here; reader/clock callbacks are native-only.
#ifndef PSYCHMETAL_KEYBOARD_QUEUE_H
#define PSYCHMETAL_KEYBOARD_QUEUE_H
#include <pthread.h>
#include <time.h>
#include <cstring>
#include <vector>
struct PMKeyEvent { double time; int key; bool pressed; };
class PMKeyboardQueue {
public:
    using Reader=void (*)(bool*,const bool*);
    using Clock=double (*)();
    static constexpr unsigned capacity=4096;
    PMKeyboardQueue(Reader r,Clock c):read(r),clock(c) { pthread_mutex_init(&mutex,nullptr); }
    ~PMKeyboardQueue() { release(); pthread_mutex_destroy(&mutex); }
    void create(const bool* filter,double seconds) {
        stop(); pthread_mutex_lock(&mutex);
        std::memcpy(mask,filter,sizeof(mask)); interval=seconds; created=true; clearLocked();
        pthread_mutex_unlock(&mutex);
    }
    bool exists() { pthread_mutex_lock(&mutex); bool v=created; pthread_mutex_unlock(&mutex); return v; }
    bool start() {
        if(!exists()) return false;
        if(isRunning()) return true;
        bool baseline[256]={}; read(baseline,mask);
        pthread_mutex_lock(&mutex); clearLocked(); std::memcpy(previous,baseline,sizeof(previous));
        stopping=false; running=true; pthread_mutex_unlock(&mutex);
        if(pthread_create(&thread,nullptr,entry,this)) {
            pthread_mutex_lock(&mutex); running=false; pthread_mutex_unlock(&mutex); return false;
        }
        return true;
    }
    void stop() {
        pthread_mutex_lock(&mutex); bool active=running; stopping=true; pthread_mutex_unlock(&mutex);
        if(active) pthread_join(thread,nullptr);
        pthread_mutex_lock(&mutex); running=false; pthread_mutex_unlock(&mutex);
    }
    void release() { stop(); pthread_mutex_lock(&mutex); created=false; clearLocked(); pthread_mutex_unlock(&mutex); }
    void flush() { pthread_mutex_lock(&mutex); clearLocked(); pthread_mutex_unlock(&mutex); }
    bool isRunning() { pthread_mutex_lock(&mutex); bool v=running; pthread_mutex_unlock(&mutex); return v; }
    std::vector<PMKeyEvent> events(unsigned long long &lost) {
        pthread_mutex_lock(&mutex); std::vector<PMKeyEvent> out; out.reserve(size);
        for(unsigned i=0;i<size;i++) out.push_back(buffer[(head+i)%capacity]);
        head=0; size=0; lost=dropped; pthread_mutex_unlock(&mutex); return out;
    }
    void check(double out[4][256]) {
        pthread_mutex_lock(&mutex); std::memcpy(out,summary,sizeof(summary));
        std::memset(summary,0,sizeof(summary)); pthread_mutex_unlock(&mutex);
    }
private:
    Reader read; Clock clock; pthread_t thread{}; pthread_mutex_t mutex;
    bool created=false,running=false,stopping=false,mask[256]={},previous[256]={};
    double interval=.002,summary[4][256]={}; PMKeyEvent buffer[capacity]{};
    unsigned head=0,size=0; unsigned long long dropped=0;
    void clearLocked() { head=0; size=0; dropped=0; std::memset(summary,0,sizeof(summary)); }
    static void* entry(void* p) { static_cast<PMKeyboardQueue*>(p)->loop(); return nullptr; }
    void loop() {
        const timespec delay={0,(long)(interval*1e9)};
        while(true) {
            pthread_mutex_lock(&mutex); bool done=stopping; pthread_mutex_unlock(&mutex);
            if(done) break;
            bool state[256]={}; read(state,mask); double stamp=clock();
            pthread_mutex_lock(&mutex);
            if(stopping) { pthread_mutex_unlock(&mutex); break; }
            for(int k=0;k<256;k++) {
                if(!mask[k] || state[k]==previous[k]) continue;
                previous[k]=state[k];
                int first=state[k]?0:1, last=state[k]?2:3;
                if(summary[first][k]==0) summary[first][k]=stamp;
                summary[last][k]=stamp;
                if(size==capacity) { head=(head+1)%capacity; size--; dropped++; }
                buffer[(head+size)%capacity]={stamp,k+1,state[k]}; size++;
            }
            pthread_mutex_unlock(&mutex); nanosleep(&delay,nullptr);
        }
    }
};
#endif
