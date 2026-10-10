# Phone menu design

The home screen uses a light gallery layout: slate typography, teal controls,
white demo cards, and a centered Gabor with a gold psychometric curve over it. The version
stays visible in the header. Static previews help identify each stimulus; they
are illustrations, not calibrated stimulus samples.

Each card keeps one native Open button leading to the teaching notes and Start
control. The timing test is hidden until Diagnostic mode is enabled.
Output and report links appear after a run produces them. Full printed output
has its own scrolling page; it does not expand the home screen.

Artwork is bundled offline and is never loaded in the timed Metal render loop.
Regenerate it with `python generate_menu_art.py` using a Python environment with
NumPy. No additional runtime dependency is needed by the phone app.
