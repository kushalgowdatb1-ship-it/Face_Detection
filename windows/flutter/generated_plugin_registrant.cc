//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <camera_windows/camera_windows.h>
#include <face_detection_tflite/face_detection_tflite_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  CameraWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("CameraWindows"));
  FaceDetectionTflitePluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FaceDetectionTflitePlugin"));
}
