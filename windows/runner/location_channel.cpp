#include "location_channel.h"

#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Devices.Geolocation.h>
#include <winrt/Windows.Foundation.h>

#include <chrono>
#include <optional>
#include <string>
#include <thread>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodResult;
using winrt::Windows::Devices::Geolocation::GeolocationAccessStatus;
using winrt::Windows::Devices::Geolocation::Geolocator;
using winrt::Windows::Devices::Geolocation::PositionAccuracy;
using winrt::Windows::Devices::Geolocation::PositionSource;
using winrt::Windows::Devices::Geolocation::PositionStatus;

// One finished call, carried from the worker thread to the window.
struct Pending {
  std::unique_ptr<MethodResult<EncodableValue>> result;
  std::optional<EncodableValue> value;  // set on success
  std::string error_code;
  std::string error_message;
};

const char* AccessName(GeolocationAccessStatus access) {
  switch (access) {
    case GeolocationAccessStatus::Allowed:
      return "allowed";
    case GeolocationAccessStatus::Denied:
      return "denied";
    default:
      return "unspecified";
  }
}

const char* StatusName(PositionStatus status) {
  switch (status) {
    case PositionStatus::Ready:
      return "ready";
    case PositionStatus::Initializing:
      return "initializing";
    case PositionStatus::NoData:
      return "noData";
    case PositionStatus::Disabled:
      return "disabled";
    case PositionStatus::NotInitialized:
      return "notInitialized";
    default:
      return "notAvailable";
  }
}

// Where Windows got the position: only a satellite fix is GPS-grade, so
// the app draws anything else as an approximate circle.
const char* SourceName(PositionSource source) {
  switch (source) {
    case PositionSource::Satellite:
      return "satellite";
    case PositionSource::WiFi:
      return "wifi";
    case PositionSource::Cellular:
      return "cellular";
    case PositionSource::IPAddress:
      return "ipAddress";
    case PositionSource::Obfuscated:
      return "obfuscated";
    default:
      return "unknown";
  }
}

const EncodableValue* Arg(const EncodableMap* args, const char* key) {
  if (args == nullptr) return nullptr;
  auto it = args->find(EncodableValue(key));
  return it == args->end() ? nullptr : &it->second;
}

// The Windows calls. Run on a worker thread (blocking .get() is not
// allowed on the UI thread's single-threaded apartment).
void Status(Pending& out) {
  const auto access = Geolocator::RequestAccessAsync().get();
  Geolocator locator;
  out.value = EncodableValue(EncodableMap{
      {EncodableValue("access"), EncodableValue(AccessName(access))},
      {EncodableValue("status"), EncodableValue(StatusName(locator.LocationStatus()))},
  });
}

void Position(const EncodableMap* args, Pending& out) {
  bool precise = true;
  if (auto value = Arg(args, "precise"); value && std::holds_alternative<bool>(*value)) {
    precise = std::get<bool>(*value);
  }
  int timeout_ms = 10000;
  if (auto value = Arg(args, "timeoutMs"); value && std::holds_alternative<int32_t>(*value)) {
    timeout_ms = std::get<int32_t>(*value);
  }

  if (Geolocator::RequestAccessAsync().get() != GeolocationAccessStatus::Allowed) {
    out.error_code = "denied";
    out.error_message = "Location is off or blocked for desktop apps.";
    return;
  }
  Geolocator locator;
  locator.DesiredAccuracy(precise ? PositionAccuracy::High : PositionAccuracy::Default);
  try {
    // Accept a position up to 30 s old: a fresh one costs seconds.
    const auto position =
        locator
            .GetGeopositionAsync(std::chrono::seconds(30), std::chrono::milliseconds(timeout_ms))
            .get();
    const auto coordinate = position.Coordinate();
    const auto point = coordinate.Point().Position();
    const auto when = std::chrono::duration_cast<std::chrono::milliseconds>(
                          winrt::clock::to_sys(coordinate.Timestamp()).time_since_epoch())
                          .count();
    out.value = EncodableValue(EncodableMap{
        {EncodableValue("latitude"), EncodableValue(point.Latitude)},
        {EncodableValue("longitude"), EncodableValue(point.Longitude)},
        {EncodableValue("accuracy"), EncodableValue(coordinate.Accuracy())},
        {EncodableValue("timestampMs"), EncodableValue(static_cast<int64_t>(when))},
        {EncodableValue("source"), EncodableValue(SourceName(coordinate.PositionSource()))},
    });
  } catch (const winrt::hresult_error& error) {
    out.error_code = "noFix";
    out.error_message = winrt::to_string(error.message());
  }
}

}  // namespace

LocationChannel::LocationChannel(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "holdfast/location", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const std::string method = call.method_name();
    if (method != "status" && method != "position") {
      result->NotImplemented();
      return;
    }
    // Copy the arguments: the call object doesn't outlive this handler.
    std::optional<EncodableMap> args;
    if (const auto* map = std::get_if<EncodableMap>(call.arguments())) args = *map;

    auto pending = new Pending{std::move(result)};
    HWND window = window_;
    std::thread([pending, method, args = std::move(args), window]() {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      try {
        if (method == "status") {
          Status(*pending);
        } else {
          Position(args ? &*args : nullptr, *pending);
        }
      } catch (const winrt::hresult_error& error) {
        pending->error_code = "unavailable";
        pending->error_message = winrt::to_string(error.message());
      } catch (...) {
        pending->error_code = "unavailable";
        pending->error_message = "The Windows location service failed.";
      }
      winrt::uninit_apartment();
      if (!PostMessage(window, kResultMessage, 0, reinterpret_cast<LPARAM>(pending))) {
        // The window is gone: nobody is waiting for the answer.
        delete pending;
      }
    }).detach();
  });
}

void LocationChannel::HandleResult(LPARAM lparam) {
  std::unique_ptr<Pending> pending(reinterpret_cast<Pending*>(lparam));
  if (pending->value) {
    pending->result->Success(*pending->value);
  } else {
    pending->result->Error(pending->error_code, pending->error_message);
  }
}
