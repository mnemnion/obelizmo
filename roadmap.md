# Obelizmo Roadmap

For Xterm purposes, this library is a competent system.  That was the initial impetus, and in some specific ways, the harder problem to solve, because of the need to re-start outer spans, and the desire to skip over zero-width style signals.

But, for all that it's a funky in-band signalling protocol, the needs which must be satisfied for XTerm are minimal.  Printing to HTML is more complex, despite the structure of the printing functions being simpler.

The first thing we need to consider is that the text for HTML needs to be filtered to replace markup charactes with their attribute form, `&lt;` and the like.

## [ ] Remove the whole limited-writer-iterator thing

I think this was just a mistake, because there's already the BufferedWriter wrapper which does this without all the insanity, and without having to maintain two versions of each function indefinitely.  Live and learn.
