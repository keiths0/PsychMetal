// Logical time for stimulus exports. Real presentation diagnostics stay physical.
// SPDX-License-Identifier: MIT
#ifndef PSYCHMETAL_RECORDING_CLOCK_H
#define PSYCHMETAL_RECORDING_CLOCK_H
#include <atomic>
#include <cstdint>
#include <algorithm>
#include <cmath>
#include <mutex>
#include <vector>
#include <stdexcept>
namespace pm { namespace recording {
// Include caller waits after the last Flip, rounded up to a complete refresh.
inline int64_t endingTick(double stopped, double first, int64_t last, double period) noexcept {
    if(last<0) return 0;
    if(!std::isfinite(stopped)) return last+1; // live-clock recording
    const double elapsed=std::ceil(std::max(0.0,(stopped-first)/period)-1e-7);
    return std::max(last+1,(int64_t)std::min(elapsed,9e18));
}
// Admission order gives Stop a final duration before the writer drains. Used
// only with settled virtual aims; protected by the owning recorder's mutex.
struct Span {
    double first=NAN;
    int64_t last=-1;
    void note(double aim,double period) {
        if(!std::isfinite(first)) first=aim;
        last=std::max(last+1,(int64_t)std::llround((aim-first)/period));
    }
    int64_t end(double stopped,double period) const noexcept {return endingTick(stopped,first,last,period);}
};
class Clock {
    mutable std::mutex mutex_;
    std::atomic<bool> active_{false};
    double origin_=0, base_=0, wall_=0, period_=0, last_=NAN, held_=0;
    double queueLogical_=NAN, queuePhysical_=NAN;
    bool frozen_=false;unsigned sequence_=0;
    struct Token {uint64_t id=0;double aim=NAN;};
    std::vector<Token> tokens_;
    double value(double wall) const { return frozen_ ? held_ : sequence_ ? base_ : base_+std::max(0.0,wall-wall_); }
public:
    double period() const noexcept { std::lock_guard<std::mutex> guard(mutex_); return period_; }
    bool active() const noexcept { return active_.load(); }
    void begin(double wall, double period) {
        std::lock_guard<std::mutex> guard(mutex_);
        if (active_ || !std::isfinite(wall) || !(period>0) || !std::isfinite(period))
            throw std::runtime_error("Invalid recording clock start.");
        tokens_.assign(16384,Token{});
        origin_=base_=wall_=wall; period_=period; last_=queueLogical_=queuePhysical_=NAN; frozen_=sequence_=false;
        active_.store(true);
    }
    void end() noexcept { std::lock_guard<std::mutex> guard(mutex_); active_.store(false); frozen_=sequence_=false; }
    double now(double wall) const noexcept {
        if (!active()) return wall;
        std::lock_guard<std::mutex> guard(mutex_);
        return active_ ? value(wall) : wall;
    }
    // Freeze until the operation finishes. Return the corresponding real target.
    double beginFlip(double wall, double target) {
        std::lock_guard<std::mutex> guard(mutex_);
        if (!active_) return target;
        if(!std::isfinite(target)||target<0) throw std::runtime_error("Invalid recording Flip target.");
        if (frozen_) throw std::runtime_error("A recording Flip is already in progress.");
        const double current=value(wall);
        const double earliest=std::max(current,std::isfinite(last_)?last_+period_:origin_);
        const double wanted=target>0?std::max(target,earliest):earliest;
        // Tolerance prevents a floating point round-off from adding a refresh.
        const double ticks=std::ceil((wanted-origin_)/period_-1e-7);
        if(!std::isfinite(ticks)||ticks>9e12) throw std::runtime_error("Recording target exceeds the clock range.");
        held_=origin_+std::max(0.0,ticks)*period_;
        frozen_=true;
        return target>0?wall+std::max(0.0,held_-current):0;
    }
    // Keep one physical anchor for the queued sequence. Re-anchoring every
    // admission after jumping logical time would reverse physical queue targets.
    double beginQueue(double wall, double target) {
        {
            std::lock_guard<std::mutex> guard(mutex_);
            if(!active_) return target;
            if(!std::isfinite(target) || target<=0 || (std::isfinite(last_) && target<=last_))
                throw std::runtime_error("Queued recording targets must increase.");
        }
        const double physical=beginFlip(wall,target);
        std::lock_guard<std::mutex> guard(mutex_);
        if(!std::isfinite(queueLogical_)) {queueLogical_=held_;queuePhysical_=physical;}
        return queuePhysical_+(held_-queueLogical_);
    }
    void rememberQueued(uint64_t token) noexcept {
        std::lock_guard<std::mutex> guard(mutex_);
        if(active_ && frozen_ && token) tokens_[token%tokens_.size()]={token,held_};
    }
    double queuedTime(uint64_t token) const noexcept {
        std::lock_guard<std::mutex> guard(mutex_);
        if(!active_ || !token || tokens_.empty()) return NAN;
        const auto &entry=tokens_[token%tokens_.size()];
        return entry.id==token?entry.aim:NAN;
    }
    double finishFlip(double wall) noexcept {
        std::lock_guard<std::mutex> guard(mutex_);
        if (!active_ || !frozen_) return active_?value(wall):wall;
        last_=base_=held_; wall_=wall; frozen_=false;
        return last_;
    }
    // Native playback owns its cadence: decoding, scene sampling and report waits
    // must not become extra held refreshes in the exported sequence.
    bool beginSequence(double wall) {
        std::lock_guard<std::mutex> guard(mutex_);
        if(!active_) return false;
        if(frozen_) throw std::runtime_error("Recording playback is already in progress.");
        if(sequence_) {++sequence_;return true;}
        base_=value(wall);wall_=wall;sequence_=1;return true;
    }
    void endSequence(double wall) noexcept {
        std::lock_guard<std::mutex> guard(mutex_);
        if(sequence_ && --sequence_==0) wall_=wall;
    }
    double advanceWait(double logical,double wall) {
        std::lock_guard<std::mutex> guard(mutex_);
        if(!active_) return wall;
        if(frozen_||!std::isfinite(logical)||logical<0||std::abs((logical-origin_)/period_)>9e12)
            throw std::runtime_error("Invalid export wait deadline.");
        base_=std::max(value(wall),logical);wall_=wall;return base_;
    }
    double align(double logical) const {
        std::lock_guard<std::mutex> guard(mutex_);
        if(!active_) return logical;
        const double ticks=std::ceil((logical-origin_)/period_-1e-7);
        if(!std::isfinite(ticks) || std::abs(ticks)>9e12) throw std::runtime_error("Recording target exceeds the clock range.");
        return origin_+ticks*period_;
    }
    double deadline(double logical, double wall) const noexcept {
        if (!active()) return logical;
        std::lock_guard<std::mutex> guard(mutex_);
        return active_?wall+std::max(0.0,logical-value(wall)):logical;
    }
};
// Keep the sequence clock restored on cancellation and all exceptions.
class Sequence {
    Clock &clock_;double (*wall_)();bool active_;
public:
    Sequence(Clock &clock,double (*wall)()) : clock_(clock),wall_(wall),active_(clock.beginSequence(wall())) {}
    ~Sequence() {if(active_) clock_.endSequence(wall_());}
    Sequence(const Sequence &)=delete;
    Sequence &operator=(const Sequence &)=delete;
};
} }
#endif
