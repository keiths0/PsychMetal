function PsychMetalDotDemo(showSprites, waitframes)
%
% dot motion demo using PsychMetal('DrawDots'), with no OpenGL in the path
%
% Usage: PsychMetalDotDemo([showSprites = 0][, waitframes = 1]);
%
% A LITERAL PORT of Psychtoolbox's DotDemo, with every Screen/OpenGL drawing
% call replaced by its PsychMetal equivalent and nothing else changed. The dot
% field parameters, the annulus geometry, the limited-lifetime rule, the
% in/out motion assignment and the frame loop are all as in the original, so
% the two can be run side by side and compared.
%
% This file is derived from Psychtoolbox-3's DotDemo.m, which is MIT licensed.
% The original copyright and history are preserved below. Everything in the
% "PORTING NOTES" section is the difference.
%
% The optional parameter 'showSprites' when set to 1, will draw little
% smiley textures instead of dots, demonstrating sprite-drawing. A zero
% setting, or omitting the setting, will draw dots. A value of 2 will draw
% filled rectangles via textures instead, (ab-)using texture drawing and
% filtering to allow subpixel positioning of drawn rectangles on the
% screen. We slow down the animation for non-zero 'showSprites' so you can
% appreciate the anti-aliased smooth subpixel movement better.
%
% 'waitframes' Number of video refresh intervals to show each image before
% updating the dot field. Defaults to 1 if omitted.
%
% You can exit the demo by any keypress or mouse button press. It will also
% exit by itself after 3600 redraws.
%
% The top of the demo code contains tons of parameters to tweak and
% manipulate if you want.
%
%
% PORTING NOTES. Four things could not be translated one for one, and each is
% marked where it occurs:
%
%   BlendFunction     the original enables GL_SRC_ALPHA/GL_ONE_MINUS_SRC_ALPHA
%                     for smoothed points. PsychMetal is fixed at exactly that
%                     blend, so the call has no equivalent and needs none.
%   Dot size limits   the original queries the gpu's smooth-point size range
%                     and clamps to it, because GL_POINTS has a hardware limit.
%                     PsychMetal draws each dot as an instanced quad with
%                     analytic coverage, so there is no such limit and no
%                     clamp. This is the one place where the port is not just
%                     equivalent but strictly better behaved.
%   DrawingFinished   an OpenGL pipeline hint with no meaning here. Dropped.
%   Sprites           PsychDrawSprites2D has no PsychMetal equivalent, so
%                     sprites are drawn as one DrawTexture per sprite. Textures
%                     do not batch the way shapes do, so this is genuinely
%                     slower; the dot path is the one to judge performance by.
%   Smiley texture    the original draws ':)' with Screen('DrawText') into an
%                     offscreen window. PsychMetal has no text drawing, so the
%                     face is constructed arithmetically instead.
%
% Note: the original carries a warning about defective dot drawing on some
% MacOS/X versions with certain NVidia hardware. That was an OpenGL point
% rendering bug and does not apply to this path.
%
% ---------------------------------------------------------------------------
% Original author: Keith Schneider, 12/13/04
% Part of Psychtoolbox-3, MIT licensed. Ported to PsychMetal 2026.
%
% HISTORY
%
% mm/dd/yy
%
% 12/13/04  kas     Wrote it.
% 1/11/05   awi     Merged into Psychtoolbox.org distribution.
% 1/13/05   awi     Merged in Mario Kleiner's modifications to agree with
%                   his changes to Screen 'DrawDots' and also time performance.
% 3/22/05   mk      Added code to show how to specify different color and
%                   size for each single dot.
% 4/23/05   mk      Add call to Screen('BlendFunction') to reenable
%                   point-smoothing.
% 4/23/05   fwc     changed color and size specifications to use 'rand',
%                   rather than 'random'.
% 5/31/05   mk      Some modifications to use new Flip command...
% 4/18/10   mk      Add support for demo'ing PsychDrawSprites2D() command.
% 12/15/15  mk      Query and obey gpu point size limits.
% 2026      --      Ported to PsychMetal: all drawing native Metal, no OpenGL.
% ---------------------------------------------------------------------------
%
% SPDX-License-Identifier: MIT

if nargin < 1
    showSprites = [];
end

if isempty(showSprites)
    showSprites = 0;
end

if nargin < 2
    waitframes = [];
end

if isempty(waitframes)
    waitframes = 1;
end

w = [];
tex = [];

try

    % ------------------------
    % set dot field parameters
    % ------------------------

    nframes     = 3600; % number of animation frames in loop
    mon_width   = 39;   % horizontal dimension of viewable screen (cm)
    v_dist      = 60;   % viewing distance (cm)
    if showSprites > 0
        dot_speed   = 0.07; % dot speed (deg/sec) - Take it sloooow.
        f_kill      = 0.00; % Don't kill (m)any dots, so user can see better.
    else
        dot_speed   = 7;    % dot speed (deg/sec)
        f_kill      = 0.05; % fraction of dots to kill each frame (limited lifetime)
    end
    ndots       = 2000; % number of dots
    max_d       = 15;   % maximum radius of  annulus (degrees)
    min_d       = 1;    % minumum
    dot_w       = 0.1;  % width of dot (deg)
    fix_r       = 0.15; % radius of fixation point (deg)
    differentcolors =1; % Use a different color for each point if == 1. Use common color white if == 0.
    differentsizes = 2; % Use different sizes for each point if >= 1. Use one common size if == 0.

    if differentsizes>0  % drawing large dots is a bit slower
        ndots=round(ndots/5);
    end

    % ---------------
    % open the screen
    % ---------------

    % Second argument is the background colour, as in Screen('OpenWindow',
    % screenNumber, 0). Each frame is cleared to it, so this line is a true
    % one-for-one translation of the original. [] is the last active display,
    % which is what max(Screen('Screens')) resolved to.
    [w, rect, ifi] = PsychMetal('OpenWindow', [], 0);

    % PORT: Screen('BlendFunction', w, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    % has no equivalent. PsychMetal blending is fixed at source alpha over
    % destination, which is exactly what that call was asking for.

    center = [(rect(1)+rect(3))/2, (rect(2)+rect(4))/2];
    fps = 1/ifi;                    % frames per second

    % PORT: WhiteIndex(w) queries a Psychtoolbox window, and w is a PsychMetal
    % token. ColorRange returns the same number for the same reason: it is the
    % value a colour component takes at full intensity.
    white = PsychMetal('ColorRange', w);
    PsychMetal('HideCursor'); % Hide the mouse cursor
    % PORT: Priority(MaxPriority(w)) raised the thread to real-time scheduling.
    % It is a Psychtoolbox mex, and loading it prints the licence banner, so it
    % is dropped rather than kept for a demo. PsychMetal has no equivalent yet;
    % if thread priority turns out to matter for the achieved rate, that is a
    % measurement to make rather than a call to copy.

    % Do initial flip...
    vbl=PsychMetal('Flip', w);

    % ---------------------------------------
    % initialize dot positions and velocities
    % ---------------------------------------

    ppd = pi * (rect(3)-rect(1)) / atan(mon_width/v_dist/2) / 360;    % pixels per degree
    pfs = dot_speed * ppd / fps;                            % dot speed (pixels/frame)
    s = dot_w * ppd;                                        % dot size (pixels)
    fix_cord = [center-fix_r*ppd center+fix_r*ppd];

    rmax = max_d * ppd; % maximum radius of annulus (pixels from center)
    rmin = min_d * ppd; % minimum
    r = rmax * sqrt(rand(ndots,1)); % r
    r(r<rmin) = rmin;
    t = 2*pi*rand(ndots,1);                     % theta polar coordinate
    cs = [cos(t), sin(t)];
    xy = [r r] .* cs;   % dot positions in Cartesian coordinates (pixels from center)

    mdir = 2 * floor(rand(ndots,1)+0.5) - 1;    % motion direction (in or out) for each dot
    dr = pfs * mdir;                            % change in radius per frame (pixels)
    dxdy = [dr dr] .* cs;                       % change in x and y per frame (pixels)

    % Create a vector with different colors for each single dot, if
    % requested:
    if (differentcolors==1)
        colvect = uint8(round(rand(3,ndots)*255));
    else
        colvect = white;
    end

    % Create a vector with different point sizes for each single dot, if
    % requested:
    if (differentsizes>0)
        s = (1+rand(1, ndots)*(differentsizes-1))*s;
    end

    % PORT: the original clamps s to the gpu's smooth-point size range here,
    % via [minsmooth,maxsmooth] = Screen('DrawDots', w). PsychMetal draws dots
    % as instanced quads with analytic coverage rather than as GL_POINTS, so
    % there is no hardware size limit to obey and no clamp to apply.

    % Wanna show textured sprites instead of dots?
    if showSprites == 1
        % PORT: the original opens an offscreen window and draws ':)' into it
        % with Screen('DrawText'). PsychMetal has no text drawing, so the
        % smiley is built arithmetically at the same 30x30 size. White, so
        % that colvect modulates it exactly as in the original.
        tex = PsychMetal('MakeTexture', w, smileyImage(30));

        % Scale down a bit, otherwise visual clutter ensues:
        s = s * 0.2;

        % Define randomly distributed rotation angles in a +/- 30 degree
        % range around a "vertical" smiley face:
        angles = (rand(1, ndots) - 0.5) * 60 + 90;
    end

    if showSprites == 2
        % A white rectangle with a transparent border, matching the original's
        % 30x30 offscreen window with [1 1 29 29] filled.
        img = zeros(30, 30, 4);
        img(2:29, 2:29, :) = 1;
        tex = PsychMetal('MakeTexture', w, img);
        s = 1;

        % Define randomly distributed rotation angles in a +/- 30 degree
        % range around a "vertical" smiley face:
        angles = (rand(1, ndots) - 0.5) * 60 + 90;
    end

    % --------------
    % animation loop
    % --------------
    for i = 1:nframes
        if (i>1)
            PsychMetal('FillOval', w, white, fix_cord);  % draw fixation dot (flip erases it)
            if showSprites
                % PORT: PsychDrawSprites2D has no equivalent. One DrawTexture
                % per sprite, which does not batch the way the dot path does.
                sz = s;
                if isscalar(sz), sz = repmat(sz, 1, ndots); end
                for q = 1:ndots
                    px = xymatrix(1,q) + center(1);
                    py = xymatrix(2,q) + center(2);
                    hq = sz(q)/2;
                    if differentcolors==1
                        tint = [double(colvect(:,q)); 255]';
                    else
                        tint = [255 255 255 255];
                    end
                    % modulateColor at argument 8, as Screen has it.
                    PsychMetal('DrawTexture', w, tex, [], ...
                        [px-hq, py-hq, px+hq, py+hq], angles(q), 1, [], tint);
                end
            else
                % Draw nice dots. All of them are one instanced draw call.
                PsychMetal('DrawDots', w, xymatrix, s, colvect, center);
            end
            % PORT: Screen('DrawingFinished') was an OpenGL pipeline hint. It
            % has no meaning on this path and is dropped.
        end

        % Break out of animation loop if any key on keyboard or any button
        % on mouse is pressed:
        if PsychMetal('KbCheck')
            break;
        end
        [mx, my, buttons]=PsychMetal('GetMouse', w); %#ok<ASGLU>
        if any(buttons)
            break;
        end

        xy = xy + dxdy; % move dots
        r = r + dr; % update polar coordinates too

        % check to see which dots have gone beyond the borders of the annuli

        r_out = find(r > rmax | r < rmin | rand(ndots,1) < f_kill); % dots to reposition
        nout = length(r_out);

        if nout

            % choose new coordinates

            r(r_out) = rmax * sqrt(rand(nout,1));
            r(r<rmin) = rmin;
            t(r_out) = 2*pi*(rand(nout,1));

            % now convert the polar coordinates to Cartesian

            cs(r_out,:) = [cos(t(r_out)), sin(t(r_out))];
            xy(r_out,:) = [r(r_out) r(r_out)] .* cs(r_out,:);

            % compute the new cartesian velocities

            dxdy(r_out,:) = [dr(r_out) dr(r_out)] .* cs(r_out,:);
        end
        xymatrix = transpose(xy);

        vbl=PsychMetal('Flip', w, vbl + (waitframes-0.5)*ifi);
    end

    if ~isempty(tex)
        PsychMetal('CloseTexture', w, tex); tex = [];
    end
    PsychMetal('Close', w); w = [];
    PsychMetal('ShowCursor');

catch e
    try, if ~isempty(tex) && ~isempty(w), PsychMetal('CloseTexture', w, tex); end; catch, end
    try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
    try, PsychMetal('ShowCursor'); catch, end
    rethrow(e);
end
end

function img = smileyImage(sz)
% Stand-in for Screen('DrawText', tex, ':)') in the original. White with an
% alpha mask, so the per-dot colour vector modulates it the same way.
[tx, ty] = meshgrid(linspace(-1,1,sz), linspace(-1,1,sz));
rad = sqrt(tx.^2 + ty.^2);
face  = (rad < 0.98) & (rad > 0.80);
eyes  = ((tx+0.33).^2 + (ty+0.28).^2 < 0.02) | ...
        ((tx-0.33).^2 + (ty+0.28).^2 < 0.02);
mr    = sqrt(tx.^2 + (ty-0.02).^2);
mouth = (mr < 0.62) & (mr > 0.46) & (ty > 0.16);
a = double(face | eyes | mouth);
img = cat(3, ones(sz), ones(sz), ones(sz), a);
end
