# Audio Module
WIP.

## Code sample

```CPP

// Init
audio.init();
audio.set_target_device_context(audio.make_device_context()); // make_device_context targets system default device if no specific device is specified.

// We can make everything in same format as the device to avoid conversions on the audio thread
device_format := audio.get_device_format();

// Make playback context, output same format as device
playback : ^audio.Playback_Context = audio.make_playback_context(device_format);

// Simple player; can play one source at a time.
player : ^audio.Simple_Player = audio.make_simple_player(playback);

// We can make an audio source streaming from a compressed file
source, ok := audio.make_source_from_file("sound.wav", .COMPRESSED, device_format); // Sampling will output device_format to playback_context which has the same format so no conversion will be needed.

// .. or we can make an audio source streaming from a file containing raw pcm data
source, ok := audio.make_source_from_file("raw_sound.pcm", .PCM, device_format);

// .. or stream compressed audio data in memory
source, ok := audio.make_source_from_memory(ptr_to_sound_data, data_size, .PCM, device_format);

// .. or simply decode a whole sound file beforehand and use that as a source
pcm_result, decode_ok := audio.decode_file_to_pcm("sound.wav", device_format);
assert(decode_ok, "audio decode fail");
source, ok := audio.make_source_from_memory(pcm_result.pcm, pcm_result.byte_size, .PCM, device_format);

// Set source for player to play back
audio.set_player_source(player, source);

// Playback control
audio.start_player(player);
audio.stop_player(player);
audio.reset_player(player);
audio.set_player(player, timestamp_in_seconds);
audio.set_player_looping(true);

// Cleanup
audio.destroy_source(source);
audio.destroy_player(player);
audio.destroy_playback_context(playback);
audio.destroy_target_device_context();
audio.shutdown();

```

## TODO
- Implement Mixed_Player
- Player settings
    - Playback speed
    - NDC position
    - 2D Velocity/Acceleration?
    - Volume
    - etc
- Positional audio
- Better resampling algorithm on format sample rate conversion
- SIMD where applicable
- Fix #Speed's
- Millisecond budget per device
- Custom latency setting per device context?
- Default device polling, move playback context & stuff to new device context.