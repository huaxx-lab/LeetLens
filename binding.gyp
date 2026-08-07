{
  "targets": [
    {
      "target_name": "liquid_glass",
      "sources": ["native/liquid_glass.mm"],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include\")"
      ],
      "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"],
      "xcode_settings": {
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
        "CLANG_CXX_LIBRARY": "libc++",
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
        "OTHER_LDFLAGS": ["-framework AppKit", "-framework ApplicationServices"]
      }
    }
  ]
}
