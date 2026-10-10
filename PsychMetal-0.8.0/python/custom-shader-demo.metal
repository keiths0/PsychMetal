// Shared by Python, MATLAB/Octave and the phone app.
float4 psychmetal_main(float2 pixel, float2 uv, constant float4* parameters) {
    float frequency=parameters[0].x, phase=parameters[0].y;
    float radius=length(pixel), angle=atan2(pixel.y,pixel.x);
    float carrier=cos(6.28318530718*frequency*radius+4*angle-phase);
    return float4(.5+.45*carrier, .5+.35*cos(phase+uv.x*6.28318530718),
                  .5-.45*carrier, 1);
}
