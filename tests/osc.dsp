// Smoke test for the Max workflow: a sine oscillator with two controls.
import("stdfaust.lib");

freq = hslider("freq [unit:Hz]", 440, 20, 2000, 1);
gain = hslider("gain", 0.1, 0, 1, 0.01) : si.smoo;

process = os.osc(freq) * gain <: _, _;
