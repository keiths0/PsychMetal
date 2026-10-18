"""Prepared GPU image-processing chains. See IMAGING.md."""
import numpy as np
from . import _core, _open, _texture, _fail
__all__ = ['create_image_pipeline', 'process_image', 'close_image_pipeline']

def _program(operations):
    if not isinstance(operations, (list, tuple)) or not 1 <= len(operations) <= 32:
        _fail('Supply a list of 1..32 image operations.')
    program = np.zeros((len(operations), 32), dtype=np.float64)
    for row, op in zip(program, operations):
        if not isinstance(op, dict):
            _fail('Each image operation must be a dictionary.')
        kind = op.get('type')
        keys = {'gaussian': {'sigma','radius'}, 'exposure': {'stops'},
                'color_matrix': {'matrix'}, 'convolution': {'kernel'}, 'affine': {'matrix'}}
        if kind not in keys or set(op) - (keys[kind] | {'type'}):
            _fail('Unknown image operation or parameter.')
        if kind == 'gaussian':
            row[:3] = [1, op.get('sigma', 2), op.get('radius', 0)]
        elif kind == 'exposure':
            row[:2] = [3, op.get('stops', 0)]
        elif kind == 'color_matrix':
            matrix = np.asarray(op.get('matrix'), dtype=float)
            if matrix.shape == (3,3): matrix = np.column_stack([matrix, np.zeros(3)])
            if matrix.shape != (3,4): _fail('Colour matrix must be 3x3 or 3x4 (bias in last column).')
            row[0] = 4; row[1:13] = matrix.ravel()
        elif kind == 'convolution':
            kernel = np.asarray(op.get('kernel'), dtype=float)
            if kernel.ndim != 2 or kernel.shape[0] != kernel.shape[1] or kernel.shape[0] not in (1,3,5):
                _fail('Convolution kernel must be 1x1, 3x3 or 5x5.')
            row[:2] = [5, kernel.shape[0]]; row[2:2+kernel.size] = kernel.ravel()
        else:
            matrix = np.asarray(op.get('matrix'), dtype=float)
            if matrix.shape != (2,3): _fail('Affine inverse pixel mapping must be 2x3.')
            row[0] = 6; row[1:7] = matrix.ravel()
    if not np.isfinite(program).all(): _fail('Image pipeline parameters must be finite.')
    return program

def create_image_pipeline(w, operations):
    """Prepare a list of named operations once, before timed processing.

    gaussian(sigma,radius), exposure(stops), color_matrix(matrix),
    convolution(kernel), affine(matrix). All intermediate work stays on GPU.
    """
    _open(w, 'create_image_pipeline')
    return _core.create_image_pipeline(_program(operations))

def process_image(w, pipeline, source, destination=None):
    """Return a filtered texture, or replace destination with a safe snapshot.

    Output dimensions equal source dimensions. Reuse destination for animation;
    close unused outputs with close_texture. Retained draws keep their versions.
    """
    _open(w, 'process_image')
    from . import _S
    src = _texture(source)
    dst = 0 if destination is None else _texture(destination)
    result = _core.process_image(pipeline, src, dst)
    _S['textures'][result] = _S['textures'][src]
    return result

def close_image_pipeline(w, pipeline):
    """Release the program/pool; output textures and in-flight draws remain valid."""
    _open(w, 'close_image_pipeline')
    return _core.close_image_pipeline(pipeline)
