// Tests production worker and queue using synthetic native reader callbacks.
#include "../PsychMetalKeyboardQueue.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <thread>
#include <iostream>
static std::atomic<bool> keys[256];
static void readKeys(bool* out,const bool* mask) { for(int k=0;k<256;k++) out[k]=mask[k]&&keys[k].load(); }
static std::atomic<double> controlledTime{0};
static double wallNow() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static double clockNow() { double t=controlledTime.load(); return t>0?t:wallNow(); }
// Let the real worker observe a state while holding its event clock fixed.
// sleep_for(6ms) is not a promise to wake before the 20ms grace on a CI host.
static void scanned(PMKeyboardQueue &q) {
 auto target=q.stats().scans+2; auto limit=wallNow()+5;
 while(q.stats().scans<target) { assert(wallNow()<limit); std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
}
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
 // Stop must wake a 100 ms wait, not sleep out the poll period.
 q.create(mask,.1); assert(q.start()); wait();
 auto stats=q.stats(); assert(stats.created && stats.running && stats.scans>=1);
 double began=clockNow(); q.stop(); assert(clockNow()-began<.08);
 assert(!q.stats().running); q.release();
 // Events with their own times. Until one has been seen, polling records as before.
 for(auto &k:keys) k=false;
 for(int k=0;k<256;k++) mask[k]=false; mask[22]=true; mask[40]=true;
 q.create(mask,.001); assert(q.start()); q.setExternal(true); wait();
 keys[22]=true; wait(); e=q.events(dropped);
 assert(e.size()==1 && e[0].pressed && q.stats().pollStamped==1 && q.stats().eventStamped==0 && q.stats().events);
 // An event arrives before polling would record the change: it is recorded once, with the event's time.
 double early=clockNow()-.004; keys[22]=false; q.post(early,23,false,.004);
 std::this_thread::sleep_for(std::chrono::milliseconds(60)); e=q.events(dropped);
 assert(e.size()==1 && !e[0].pressed && e[0].time==early && q.stats().eventStamped==1 && q.stats().pollStamped==1);
 assert(q.stats().maxEventDelay==.004);
 q.check(summary); assert(summary[1][22]==early && summary[3][22]==early);
 // Polling sees the change first and waits; the event then supplies the time.
 double before=clockNow(); controlledTime=before; keys[40]=true; scanned(q); assert(q.events(dropped).empty());
 q.post(before,41,true,.012); controlledTime=0; e=q.events(dropped); assert(e.size()==1 && e[0].key==41 && e[0].time==before);
 std::this_thread::sleep_for(std::chrono::milliseconds(60)); assert(q.events(dropped).empty()); // not recorded twice
 // No event arrives: after the grace period polling records it, with the time it first saw it.
 before=clockNow(); controlledTime=before; keys[40]=false; scanned(q); controlledTime=before+.060; scanned(q); e=q.events(dropped); controlledTime=0;
 assert(e.size()==1 && !e[0].pressed && e[0].time==before && q.stats().pollStamped==2);
 // An event for an unwatched key, or one that repeats the known state, records nothing.
 q.post(clockNow(),5,true,0); q.post(clockNow(),41,false,0); assert(q.events(dropped).empty());
 // A press and release inside the grace period with no event for the key: polling records both, and
 // events that then arrive late for them are not recorded again.
 std::this_thread::sleep_for(std::chrono::milliseconds(40));
 before=clockNow(); controlledTime=before; keys[22]=true; scanned(q); controlledTime=before+.006; keys[22]=false;
 scanned(q); e=q.events(dropped);
 assert(e.size()==2 && e[0].key==23 && e[0].pressed && !e[1].pressed && e[0].time>=before && e[1].time>e[0].time);
 q.post(before+.001,23,true,.03); q.post(before+.005,23,false,.03); assert(q.events(dropped).empty()); controlledTime=0;
 // Flush is a barrier for events too: one stamped before it and delivered after it is not recorded,
 // but the state it reports is kept, so the release that follows is.
 double pressedAt=clockNow(); keys[40]=true; q.flush(); q.post(pressedAt,41,true,.002);
 std::this_thread::sleep_for(std::chrono::milliseconds(40)); assert(q.events(dropped).empty());
 double releasedAt=clockNow(); keys[40]=false; q.post(releasedAt,41,false,.001); e=q.events(dropped);
 assert(e.size()==1 && e[0].key==41 && !e[0].pressed && e[0].time==releasedAt);
 q.setExternal(false); assert(!q.stats().events); q.post(clockNow(),41,true,0); assert(q.events(dropped).empty());
 keys[40]=true; wait(); assert(q.events(dropped).size()==1);   // polling alone again, at once
 q.release();
 std::cout<<"PASS: worker latching, holds, mask, HID codes, timestamps, Check/FIFO independence, stop/restart, flush/release, "
            "overflow, and posted events: their times, the grace period and the polling safety net.\n";
}
