function report = PsychMetalTextureDemo(seconds)
% PsychMetalTextureDemo  Native Metal textures: upload once, draw many.
%
%   report = PsychMetalTextureDemo(20)
%
% Click any mouse button to stop.
%
% Three things are on screen, all drawn by Metal with no OpenGL:
%
%   Left    a static RGB image, rotating, drawn from one uploaded texture.
%   Middle  the SAME texture drawn several more times at different sizes and
%           tints, to show that one upload serves many draws.
%   Right   a counterphasing Gaussian blob that follows the mouse anywhere on
%           screen, and so passes over the other two. It is uploaded
%           ONCE as a texture and modulated by the tint alpha rather than
%           re-uploaded per frame.
%
% The right-hand blob is the interesting one. Re-uploading a texture every
% refresh is the usual way people animate contrast, and it is also the usual
% reason a stimulus loop misses frames. Here the pixels never change: only the
% tint does, which is four floats per draw.
%
% Compare with PsychMetalBlobDemo, which produces the same percept with no
% texture at all by evaluating the Gaussian in the fragment shader. For a
% parametric envelope that is better. Textures earn their place for arbitrary
% images: photographs, noise, anything not expressible in closed form.
%
% ORDERING is checked too: a small rectangle is drawn AFTER the left texture
% and should appear on top of it.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(seconds), seconds = 20; end
w = []; texRGB = []; texBlob = [];

try
 screen = [];   % [] is the last active display
 [w, rect, ifi] = PsychMetal('OpenWindow', screen);
 PsychMetal('HideCursor');
 W = rect(3); H = rect(4);

 % --- an RGB image, built once -------------------------------------------
 n = 256;
 [xx, yy] = meshgrid(linspace(-1,1,n), linspace(-1,1,n));
 rr = sqrt(xx.^2 + yy.^2);
 img = zeros(n, n, 3);
 img(:,:,1) = 0.5 + 0.5*sin(8*xx);
 img(:,:,2) = 0.5 + 0.5*sin(8*yy);
 img(:,:,3) = max(0, 1 - rr);
 texRGB = PsychMetal('MakeTexture', w, img);

 % --- a Gaussian blob, uploaded once -------------------------------------
 m = 256;
 [bx, by] = meshgrid(linspace(-3,3,m), linspace(-3,3,m));
 gauss = exp(-(bx.^2 + by.^2)/2);
 % White RGB with the envelope in alpha. Contrast and sign then come entirely
 % from the tint at draw time, so the pixels are uploaded exactly once.
 blob = cat(3, ones(m,m), ones(m,m), ones(m,m), gauss);
 texBlob = PsychMetal('MakeTexture', w, blob);

 total = round(seconds / ifi);
 sampleTime = nan(total,1);
 frames = 0;
 t0 = PsychMetal('GetSecs');
 side = min(W, H) * 0.22;

 fprintf('\nOne RGB texture drawn several times, plus a blob texture whose\n');
 fprintf('contrast is animated by tint alone. Click to stop.\n');

 for k = 1:total
  sampleTime(k) = PsychMetal('GetSecs');
  [mx, my, buttons] = PsychMetal('GetMouse', w);
  if any(buttons), break; end
  frames = k;
  t = sampleTime(k) - t0;

  PsychMetal('FillRect', w, 128);

  % Left: rotating, full colour.
  cx = W * 0.20; cy = H * 0.5;
  PsychMetal('DrawTexture', w, texRGB, [], ...
      [cx-side, cy-side, cx+side, cy+side], t * 20);

  % Drawn AFTER the texture, so it must appear on top.
  PsychMetal('FrameRect', w, [255 255 0], ...
      [cx-side, cy-side, cx+side, cy+side], 4);

  % Middle: the same texture again, smaller and tinted.
  for j = 1:3
   s2 = side * (0.55 - 0.12*j);
   mxc = W * 0.50; myc = H * (0.25 + 0.25*j);
   PsychMetal('DrawTexture', w, texRGB, [], ...
       [mxc-s2, myc-s2, mxc+s2, myc+s2], -t * 30, ...
       [1, 1 - 0.3*j, 0.3*j, 1]);
  end

  % Right: contrast animated by tint alpha only. Same texture every frame.
  % The blob follows the pointer anywhere on screen, clamped only so that it
  % stays wholly visible. An earlier version clamped x into a narrow band,
  % which pinned horizontal motion unless the pointer was already inside it.
  c = 0.5 * sin(2*pi*1.0*t);
  bx0 = min(max(mx, side), W - side);
  by0 = min(max(my, side), H - side);
  if c >= 0
   tint = [1 1 1 min(1, 2*c)];
  else
   tint = [0 0 0 min(1, -2*c)];
  end
  PsychMetal('DrawTexture', w, texBlob, [], ...
      [bx0-side, by0-side, bx0+side, by0+side], 0, tint);

  PsychMetal('Flip', w);
 end

 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 nn = min(frames, numel(d.flipNumber));
 % Report both with and without a settling allowance. The demos used to quote
 % the whole run, which folds window startup into the rate; PsychMetalPrimitives
 % Demo already discarded 120 frames, so the demos were not comparable with each
 % other. If these two numbers differ much, the run had not settled.
 warmup = min(120, round(nn/3));
 stAll = PsychMetalFrameStats(d, ifi);
 st = PsychMetalFrameStats(d, ifi, warmup);

 report = struct('ifi', ifi, 'frames', nn, ...
     'achievedHz', st.achievedHz, 'skipped', st.skipped, ...
     'texturesCreated', d.summary.texturesCreated, ...
     'texturesDrawn', d.summary.texturesDrawn, ...
     'summary', d.summary);

 fprintf('\n===== native Metal textures =====\n');
 fprintf('Textures created %d; texture draws %d over %d frames (%.1f per frame)\n', ...
     report.texturesCreated, report.texturesDrawn, nn, report.texturesDrawn / max(1,nn));
 fprintf('RATE: %.3f presentations/s; skipped %d\n', ...
     report.achievedHz, report.skipped);
 fprintf('       %.3f/s if the first %d settling frames are kept (skipped %d)\n', ...
     stAll.achievedHz, warmup, stAll.skipped);
 if report.texturesCreated ~= 2
  fprintf('Expected exactly 2 uploads. More means something re-uploaded per frame.\n');
 end
 fprintf(['The yellow frame is drawn after the left texture and should be on\n' ...
     'top of it. If it is underneath, call ordering is broken.\n']);

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end
