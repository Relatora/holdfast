#ifndef RUNNER_LOCATION_CHANNEL_H_
#define RUNNER_LOCATION_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// The `holdfast/location` method channel: the Windows location service
// (Windows.Devices.Geolocation) for "Go to my location". The geolocator
// plugin has no Windows implementation, so the app talks to the system here.
//
// The Windows calls block (the service may take seconds to answer), so each
// one runs on a worker thread. Flutter only accepts replies on the platform
// thread, so the worker posts the answer back to the window as a
// kResultMessage, and the window procedure hands it to HandleResult.
//
// Methods (results are maps of plain values):
//   status   -> {access: allowed|denied|unspecified,
//                status: ready|initializing|noData|disabled|notInitialized|
//                        notAvailable}
//   position {precise: bool, timeoutMs: int}
//            -> {latitude, longitude, accuracy, timestampMs,
//                source: satellite|wifi|cellular|ipAddress|unknown|...}
//            error "noFix" when nothing came in time, "denied" when blocked.
class LocationChannel {
 public:
  static constexpr UINT kResultMessage = WM_APP + 0x48;

  LocationChannel(flutter::BinaryMessenger* messenger, HWND window);

  // Delivers a worker's answer. Call from the window procedure when it
  // receives kResultMessage, passing its LPARAM.
  static void HandleResult(LPARAM lparam);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
};

#endif  // RUNNER_LOCATION_CHANNEL_H_
