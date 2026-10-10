// PsychMetal 0.8.0 development: host-independent timeline sampling core, and the
// account of what the display showed.
// SPDX-License-Identifier: MIT
#ifndef PSYCHMETAL_TIMELINE_H
#define PSYCHMETAL_TIMELINE_H
#include <algorithm>
#include <cstddef>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
namespace pm { namespace timeline {
// Periods are even integers so a cycle always samples both extrema. A caller
// chooses frame index explicitly: presentation integration must not infer it
// from irregular host-loop times. Frame zero is the maximum.
inline uint64_t periodFor(double measuredHz, double requestedHz) {
    if(!std::isfinite(measuredHz) || measuredHz<=0 || !std::isfinite(requestedHz) || requestedHz<=0 || requestedHz>measuredHz/2)
        throw std::invalid_argument("Frequency must be positive and no greater than half the measured refresh.");
    double pairs=std::max(1.0,std::round(measuredHz/requestedHz/2));
    if(pairs>=double(std::numeric_limits<uint64_t>::max()/2))
        throw std::invalid_argument("Temporal period is too large.");
    return uint64_t(pairs)*2;
}
inline double oscillation(uint64_t frame, uint64_t period) {
    if(period<2 || period%2) throw std::invalid_argument("Oscillation period must be an even integer >=2.");
    const uint64_t phase=frame%period;
    if(phase==0) return 1;
    if(phase==period/2) return -1;
    return std::cos(6.283185307179586476925286766559*double(phase)/double(period));
}
struct Track {
    uint64_t drawIndex, parameter, kind, period;
    double amplitude, offset;
};
inline double value(const Track &track, uint64_t frame) {
    return track.offset+track.amplitude*(track.kind==0 ? oscillation(frame,track.period) :
        double(frame%track.period)/double(track.period));
}
struct Keyframe { uint64_t frame; double value; };
// Validation occurs when installing a track, outside the rendering callback.
inline void validate(const Keyframe *keys, std::size_t count) {
    if(!keys || !count) throw std::invalid_argument("A track requires keyframes.");
    for(std::size_t i=0;i<count;i++) {
        if(!std::isfinite(keys[i].value) || (i && keys[i].frame<=keys[i-1].frame))
            throw std::invalid_argument("Keyframes must be finite and strictly ordered.");
    }
}
// Allocation-free interpolation. Input must first pass validate(). Values hold
// before the first/after the last keyframe; integer differences avoid loss of
// precision when a long-running frame counter exceeds double's exact range.
inline double sample(const Keyframe *keys, std::size_t count, uint64_t frame) noexcept {
    if(frame<=keys[0].frame) return keys[0].value;
    if(frame>=keys[count-1].frame) return keys[count-1].value;
    std::size_t low=0,high=count-1;
    while(high-low>1) { std::size_t middle=low+(high-low)/2;
        if(keys[middle].frame<=frame) low=middle; else high=middle;
    }
    double alpha=double(frame-keys[low].frame)/double(keys[high].frame-keys[low].frame);
    return keys[low].value*(1-alpha)+keys[high].value*alpha;
}
// What the display reported of a playback's samples, noted in order as the
// reports arrive. A sample is late when it appeared more than half a refresh
// after one refresh per sample since the last shown sample: the sample before it
// stayed on screen too long because a refresh was missed or the display slowed
// down. A sample the display reported never shown is not noted (the caller sees
// it as one fewer shown); the sample before it stayed a refresh longer.
struct Presentations {
    double period = 0;                  // the nominal refresh period, seconds
    uint64_t shown = 0, late = 0, lateRefreshes = 0;
    uint64_t firstLate = std::numeric_limits<uint64_t>::max();
    double spanSeconds = 0, longest = 0;
    uint64_t spanSamples = 0;
    void note(uint64_t sample, double presented) noexcept {
        if(!(presented > 0)) return;
        if(shown && sample > lastSample) {
            const double interval = presented - lastTime;
            const uint64_t steps = sample - lastSample;
            spanSeconds += interval;
            spanSamples += steps;
            longest = std::max(longest, interval);
            if(interval > (double(steps) + 0.5) * period) {
                ++late;
                const double refreshes = std::round(interval / period);
                if(refreshes > double(steps)) lateRefreshes += uint64_t(refreshes) - steps;
                if(firstLate == std::numeric_limits<uint64_t>::max()) firstLate = sample;
            }
        }
        if(!shown || sample > lastSample) { lastSample = sample; lastTime = presented; }
        ++shown;
    }
    // Seconds each sample was on screen, on average, between the first and the
    // last shown: the period the stimulus actually had.
    double meanSampleSeconds() const noexcept {
        return spanSamples ? spanSeconds / double(spanSamples) : std::numeric_limits<double>::quiet_NaN();
    }
private:
    uint64_t lastSample = 0;
    double lastTime = 0;
};
} }
#endif
