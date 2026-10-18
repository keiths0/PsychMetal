# Building and publishing Python releases

Tests select the numerically newest `PsychMetal-MAJOR.MINOR.PATCH` package
in the checked-out branch. Its directory, VERSION and Python project version
must agree. No workflow version edit is needed for a new package folder.

Tag-triggered Wheels builds resolve `vMAJOR.MINOR.PATCH` to one commit and build
that package from that commit. Tag builds never publish to PyPI automatically.

For an existing tag, run the corrected workflow **from main**, supplying the
source tag as an input. Running the workflow from the old tag would use the
old workflow file preserved there.

Build and verify first (no PyPI upload):

```bash
gh workflow run wheels.yml --repo keiths0/PsychMetal --ref main \
  -f release_tag=v0.11.0 -f publish_pypi=false
```

To build, verify and publish using the configured PyPI Trusted Publisher:

```bash
gh workflow run wheels.yml --repo keiths0/PsychMetal --ref main \
  -f release_tag=v0.11.0 -f publish_pypi=true
```

Replace only the release_tag value for future releases. The publisher uses the
`pypi` GitHub environment and requires an explicit tag. Every wheel and source
archive is checked for project name and version before publishing. The source
checkout uses the resolved commit even if main has advanced. Already published
PyPI distribution files cannot be replaced; do not rerun publication for the
same files. App Store submission remains separate.
