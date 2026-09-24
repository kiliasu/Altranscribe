if(MSVC)
  string(REGEX REPLACE "/RTC[^ ]*" "" CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG}")
endif()

add_library(alt_rnnoise STATIC
  rnnoise/src/denoise.c rnnoise/src/rnn.c rnnoise/src/pitch.c
  rnnoise/src/kiss_fft.c rnnoise/src/celt_lpc.c rnnoise/src/nnet.c
  rnnoise/src/nnet_default.c rnnoise/src/parse_lpcnet_weights.c
  rnnoise/src/rnnoise_data.c rnnoise/src/rnnoise_tables.c)
target_include_directories(alt_rnnoise PUBLIC rnnoise/include PRIVATE rnnoise/src)
target_compile_definitions(alt_rnnoise PRIVATE USE_WEIGHTS_FILE RNNOISE_BUILD _CRT_SECURE_NO_WARNINGS)
if(MSVC)
  target_compile_definitions(alt_rnnoise PRIVATE OPUS_X86_MAY_HAVE_SSE2)
endif()

add_library(alt_resampler STATIC speex/resample.c)
target_include_directories(alt_resampler PUBLIC speex)
target_compile_definitions(alt_resampler PUBLIC OUTSIDE_SPEEX RANDOM_PREFIX=altranscribe PRIVATE FLOATING_POINT)

# DSP must stay real time in the Flutter debug build as well.
if(MSVC)
  target_compile_options(alt_rnnoise PRIVATE /O2 /wd4244 /wd4305)
  target_compile_options(alt_resampler PRIVATE /O2 /wd4244 /wd4305)
endif()
