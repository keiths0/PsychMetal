// Render scheduled generated sounds on the export clock using the SAME mixer.
// No device callback touches this object. One host logs; one worker renders.
// SPDX-License-Identifier: MIT
#ifndef PSYCHMETAL_OFFLINE_AUDIO_H
#define PSYCHMETAL_OFFLINE_AUDIO_H
#include "PsychMetalAudio.h"
#include <algorithm>
#include <array>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <unordered_set>
namespace pm { namespace audio {
class OfflineAudio {
    struct Entry { Command command; std::shared_ptr<const Sound> sound; double issued; };
    std::mutex mutex_;
    std::vector<Entry> entries_;
    std::unordered_set<const Sound *> retained_;
    size_t bytes_=0, next_=0;
    std::atomic<bool> failed_{false};
    std::atomic<double> rendered_{-INFINITY};
    std::unique_ptr<Mixer> mixer_=std::make_unique<Mixer>();
    std::array<std::array<float,1024>,32> samples_{};
    std::array<float *,32> pointers_{};
    std::array<float,2048> interleaved_{};
    double origin_, rate_;
    uint32_t channels_;
    uint64_t cursor_=0;
    void collect() {
        Event e; while(mixer_->events.pop(e))
            if(e.status==Event::Refused) throw std::runtime_error("Too many simultaneous sounds in the movie.");
        uint64_t voice; while(mixer_->retired.pop(voice)) {}
    }
public:
    OfflineAudio(double origin, double rate, uint32_t channels):origin_(origin),rate_(rate),channels_(channels) {
        if(!std::isfinite(origin)||!(rate>0)||!std::isfinite(rate)||channels<1||channels>32)
            throw std::runtime_error("Invalid offline audio format.");
        for(uint32_t c=0;c<channels;c++) pointers_[c]=samples_[c].data();
    }
    // Worker, before rendering: anchor the sample grid at the first video frame.
    // Include whole-sample pre-roll so earlier sound commands retain their phase.
    void alignTo(double firstFrame) {
        std::lock_guard<std::mutex> guard(mutex_);
        if(cursor_ || next_ || !std::isfinite(firstFrame))
            throw std::runtime_error("Offline sample grid must be aligned before rendering.");
        const double samples=std::ceil(std::max(0.0,(firstFrame-origin_)*rate_)-1e-5);
        origin_=firstFrame-std::max(0.0,samples)/rate_;
    }
    bool failed() const noexcept { return failed_.load(); }
    // Fail the export rather than silently dropping a scheduled command.
    void capture(Command command, std::shared_ptr<const Sound> sound, double issued, bool frameKeyed=false) noexcept {
        try {
            std::lock_guard<std::mutex> guard(mutex_);
            // A frame may be queued ahead physically while the export clock has
            // advanced to its aim. Install frame-keyed commands at their intended
            // onset, provided the worker has not claimed those PCM samples yet.
            if(frameKeyed && std::isfinite(command.when)) {
                issued=std::min(issued,command.when);
                if(issued<origin_-0.5/rate_) throw std::runtime_error("Frame audio precedes the recording clock.");
            }
            if(!std::isfinite(issued)||!std::isfinite((issued-origin_)*rate_)||std::abs((issued-origin_)*rate_)>9e18||issued+0.5/rate_<rendered_.load()||entries_.size()>=65536||
               (command.kind==Command::Play && (!sound||sound.get()!=command.sound)))
                throw std::runtime_error("Offline audio command limit or retroactive command.");
            if(sound && !retained_.count(sound.get())) {
                const size_t bytes=sound->samples.size()*sizeof(float);
                if(bytes>256u*1024u*1024u-bytes_) throw std::runtime_error("Offline audio memory limit.");
                retained_.insert(sound.get());bytes_+=bytes;
            }
            if(std::isnan(command.when)) command.when=issued;
            command.generation=0; // actual-device interruptions do not alter intended sound
            const auto position=std::upper_bound(entries_.begin()+next_,entries_.end(),issued,
                [](double time,const Entry &entry){return time<entry.issued;});
            entries_.insert(position,{command,std::move(sound),issued});
        } catch(...) { failed_.store(true); }
    }
    // Worker only. sink receives interleaved stereo and its logical first-sample time.
    template<class Sink> void renderUntil(double horizon, Sink sink) {
        if(!std::isfinite(horizon)||horizon<origin_) return;
        const double target=(horizon-origin_)*rate_;
        if(target>9e18) throw std::runtime_error("Offline audio duration exceeds clock range.");
        const uint64_t end=(uint64_t)std::floor(target+1e-5);
        while(cursor_<end) {
            if(failed()) throw std::runtime_error("Movie audio command/memory limit exceeded or a command was backdated.");
            Entry entry;bool consume=false;uint32_t n=0;
            const double onset=origin_+(double)cursor_/rate_;
            {
                std::lock_guard<std::mutex> guard(mutex_);
                const bool have=next_<entries_.size();
                const double at=have?(entries_[next_].issued-origin_)*rate_:INFINITY;
                const uint64_t due=have?(uint64_t)std::max(0.0,std::round(at)):UINT64_MAX;
                if(have && due<=cursor_) {
                    entry=entries_[next_++];consume=true;
                    rendered_.store(std::max(rendered_.load(),onset));
                }
                else {
                    n=(uint32_t)std::min<uint64_t>(1024,std::min(end,due)-cursor_);
                    // Claim before unlocking, not after sink/render: admission
                    // cannot insert an earlier command while these samples run.
                    rendered_.store(origin_+(double)(cursor_+n)/rate_);
                }
            }
            if(consume) {
                if(!mixer_->commands.push(entry.command)) throw std::runtime_error("Movie audio command queue is full.");
                mixer_->render(pointers_.data(),channels_,0,onset,rate_);
                collect();continue;
            }
            mixer_->render(pointers_.data(),channels_,n,onset,rate_); collect();
            for(uint32_t i=0;i<n;i++) {
                interleaved_[2*i]=samples_[0][i];
                interleaved_[2*i+1]=samples_[channels_>1?1:0][i];
            }
            sink(onset,interleaved_.data(),n);
            cursor_+=n;
        }
    }
};
} }
#endif
