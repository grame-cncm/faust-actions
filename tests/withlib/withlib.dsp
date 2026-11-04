// Test for the archive input: a program importing a local library.
// Pack it with: COPYFILE_DISABLE=1 tar -cf - withlib.dsp mylib.lib | gzip -9 | base64
import("stdfaust.lib");
import("mylib.lib");

freq = hslider("freq [unit:Hz]", 220, 20, 2000, 1);
gain = hslider("gain", 0.1, 0, 1, 0.01) : si.smoo;

process = detuned(freq) * gain <: _, _;
