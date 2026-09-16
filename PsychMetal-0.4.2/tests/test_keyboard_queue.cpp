// Tests production worker and queue using synthetic native reader callbacks.
#include "../PsychMetalKeyboardQueue.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <thread>
#include <iostream>
static std::atomic<bool> keys[256];
static void readKeys(bool* out,const bool* mask) { for(int k=0;k<256;k++) out[k]=mask[k]&&keys[k].load(); }
static double clockNow() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static void wait() { std::this_thread::sleep_for(std::chrono::milliseconds(12)); }
int main() {
 PMKeyboardQueue q(readKeys,clockNow); bool mask[256]={}; mask[22]=true; mask[40]=true;
 q.create(mask,.001); keys[22]=true; assert(q.start()); wait();
 unsigned long long dropped; assert(q.events(dropped).empty()); // held baseline
 keys[22]=false; wait(); keys[22]=true; wait(); keys[22]=true; wait(); keys[22]=false; wait();
 keys[0]=true; wait(); // filtered key
 auto e=q.events(dropped); assert(e.size()==3 && dropped==0);
 assert(e[0].key==23 && !e[0].pressed && e[1].pressed && !e[2].pressed);
 assert(e[0].time<=e[1].time && e[1].time<=e[2].time);
 assert(q.events(dropped).empty()); double summary[4][256]; q.check(summary);
 assert(summary[0][22]==e[1].time && summary[1][22]==e[0].time && summary[3][22]==e[2].time);
 q.check(summary); assert(summary[0][22]==0 && summary[3][22]==0);
 keys[40]=true; wait(); q.check(summary); assert(summary[0][40]>0);
 assert(q.events(dropped).size()==1); // Check did not drain FIFO
 q.stop(); keys[40]=false; wait(); assert(q.events(dropped).empty());
 assert(q.start()); wait(); assert(q.events(dropped).empty());
 keys[22]=true; wait(); q.flush(); assert(q.events(dropped).empty()); wait(); assert(q.events(dropped).empty());
 keys[22]=false; wait(); assert(q.events(dropped).size()==1);
 q.release(); assert(!q.exists()&&!q.isRunning());
 // Overflow via many simultaneous changes: 20 scans * 256 > 4096 events.
 for(int k=0;k<256;k++) { mask[k]=true; keys[k]=false; }
 q.create(mask,.001); assert(q.start());
 for(int j=0;j<20;j++) { for(auto &k:keys) k=(j%2==0); wait(); }
 q.stop(); e=q.events(dropped); assert(e.size()==4096 && dropped==1024);
 q.flush(); assert(q.events(dropped).empty() && dropped==0);
 q.release();
 std::cout<<"PASS: worker latching, holds, mask, HID codes, timestamps, Check/FIFO independence, stop/restart, flush/release and overflow.\n";
}
