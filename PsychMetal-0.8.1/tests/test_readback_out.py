"""Reusable Python output buffers through the actual front end and mock engine."""
import numpy as np
import psychmetal as pm

def exercise():
    for bits in (8,10):
        with pm.open_window(readback=True,bit_depth=bits) as (w,rect,ifi):
            pm.fill_rect(w,[17,99,201]);pm.flip(w)
            roi=[2,3,11,10]
            reference=pm.get_image(w,roi)
            out=np.empty_like(reference)
            assert pm.get_image(w,roi,out=out) is out
            np.testing.assert_array_equal(out,reference)
            pm.fill_rect(w,[201,17,99]);pm.flip(w)
            assert pm.get_image(w,roi,out=out) is out
            np.testing.assert_array_equal(out,pm.get_image(w,roi))
            assert not np.array_equal(out,reference)
            whole=pm.get_image(w); assert pm.get_image(w,out=whole) is whole
            readonly=out.copy();readonly.flags.writeable=False
            bad=[readonly,out[:,:,:2],out[:,:,::-1],out.astype(float),out.astype(np.uint16 if bits==8 else np.uint8)]
            if bits==10:bad.append(out.astype('>u2'))
            for dest in bad:
                before=dest.copy()
                try:pm.get_image(w,roi,out=dest)
                except (ValueError,BufferError,TypeError,pm.PsychMetalError):pass
                else:raise AssertionError('invalid output accepted')
                np.testing.assert_array_equal(dest,before)
pm.run(exercise)
print('PASS: reusable readback outputs, identity, latest frame, crops, dtype/shape/read-only/contiguity/endian rejection.')
