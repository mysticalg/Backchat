#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kWindowChannelName[] = "backchat/window";
constexpr int kOverlayIconSize = 32;

std::wstring BadgeTextForCount(int count) {
  if (count > 9) {
    return L"9+";
  }
  return std::to_wstring(count);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }

  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  ConfigureWindowChannel();

  if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                                 CLSCTX_INPROC_SERVER,
                                 IID_PPV_ARGS(&taskbar_list_)))) {
    taskbar_list_->HrInit();
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  ClearOverlayIcon();
  window_channel_.reset();
  taskbar_list_.Reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_ACTIVATE:
      if (LOWORD(wparam) != WA_INACTIVE) {
        StopTaskbarFlash();
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::ConfigureWindowChannel() {
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), kWindowChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setUnreadCount") {
          result->NotImplemented();
          return;
        }

        int count = 0;
        const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments != nullptr) {
          const auto count_it = arguments->find(flutter::EncodableValue("count"));
          if (count_it != arguments->end()) {
            if (const auto* int_value =
                    std::get_if<int>(&count_it->second)) {
              count = *int_value;
            } else if (const auto* long_value =
                           std::get_if<int64_t>(&count_it->second)) {
              count = static_cast<int>(*long_value);
            }
          }
        }

        SetUnreadCount(count);
        result->Success();
      });
}

void FlutterWindow::SetUnreadCount(int count) {
  const int previous_count = unread_count_;
  unread_count_ = count < 0 ? 0 : count;

  if (!taskbar_list_ || GetHandle() == nullptr) {
    return;
  }

  if (unread_count_ == 0) {
    taskbar_list_->SetOverlayIcon(GetHandle(), nullptr, L"No unread messages");
    ClearOverlayIcon();
    StopTaskbarFlash();
    return;
  }

  ClearOverlayIcon();
  overlay_icon_ = CreateUnreadOverlayIcon(unread_count_);
  const std::wstring description =
      std::to_wstring(unread_count_) + L" unread messages";
  taskbar_list_->SetOverlayIcon(GetHandle(), overlay_icon_, description.c_str());

  if (unread_count_ > previous_count && GetForegroundWindow() != GetHandle()) {
    FlashTaskbar();
  }
}

void FlutterWindow::FlashTaskbar() {
  FLASHWINFO info{};
  info.cbSize = sizeof(info);
  info.hwnd = GetHandle();
  info.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
  info.uCount = 3;
  FlashWindowEx(&info);
}

void FlutterWindow::StopTaskbarFlash() {
  FLASHWINFO info{};
  info.cbSize = sizeof(info);
  info.hwnd = GetHandle();
  info.dwFlags = FLASHW_STOP;
  FlashWindowEx(&info);
}

HICON FlutterWindow::CreateUnreadOverlayIcon(int count) {
  BITMAPV5HEADER bi{};
  bi.bV5Size = sizeof(BITMAPV5HEADER);
  bi.bV5Width = kOverlayIconSize;
  bi.bV5Height = -kOverlayIconSize;
  bi.bV5Planes = 1;
  bi.bV5BitCount = 32;
  bi.bV5Compression = BI_BITFIELDS;
  bi.bV5RedMask = 0x00FF0000;
  bi.bV5GreenMask = 0x0000FF00;
  bi.bV5BlueMask = 0x000000FF;
  bi.bV5AlphaMask = 0xFF000000;

  HDC screen_dc = GetDC(nullptr);
  void* bits = nullptr;
  HBITMAP color_bitmap =
      CreateDIBSection(screen_dc, reinterpret_cast<BITMAPINFO*>(&bi),
                       DIB_RGB_COLORS, &bits, nullptr, 0);
  HBITMAP mask_bitmap = CreateBitmap(kOverlayIconSize, kOverlayIconSize, 1, 1, nullptr);
  HDC memory_dc = CreateCompatibleDC(screen_dc);

  ReleaseDC(nullptr, screen_dc);

  if (color_bitmap == nullptr || mask_bitmap == nullptr || memory_dc == nullptr) {
    if (memory_dc != nullptr) {
      DeleteDC(memory_dc);
    }
    if (color_bitmap != nullptr) {
      DeleteObject(color_bitmap);
    }
    if (mask_bitmap != nullptr) {
      DeleteObject(mask_bitmap);
    }
    return nullptr;
  }

  ZeroMemory(bits, kOverlayIconSize * kOverlayIconSize * 4);

  HGDIOBJ previous_bitmap = SelectObject(memory_dc, color_bitmap);
  HBRUSH badge_brush = CreateSolidBrush(RGB(226, 59, 59));
  HGDIOBJ previous_brush = SelectObject(memory_dc, badge_brush);
  HPEN badge_pen = CreatePen(PS_SOLID, 1, RGB(226, 59, 59));
  HGDIOBJ previous_pen = SelectObject(memory_dc, badge_pen);

  Ellipse(memory_dc, 0, 0, kOverlayIconSize - 1, kOverlayIconSize - 1);

  SetBkMode(memory_dc, TRANSPARENT);
  SetTextColor(memory_dc, RGB(255, 255, 255));

  LOGFONTW log_font{};
  log_font.lfHeight = -14;
  log_font.lfWeight = FW_BOLD;
  wcscpy_s(log_font.lfFaceName, L"Segoe UI");
  HFONT font = CreateFontIndirectW(&log_font);
  HGDIOBJ previous_font = SelectObject(memory_dc, font);

  RECT text_rect{0, 0, kOverlayIconSize, kOverlayIconSize};
  const std::wstring text = BadgeTextForCount(count);
  DrawTextW(memory_dc, text.c_str(), static_cast<int>(text.size()), &text_rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE);

  ICONINFO icon_info{};
  icon_info.fIcon = TRUE;
  icon_info.hbmMask = mask_bitmap;
  icon_info.hbmColor = color_bitmap;
  HICON icon = CreateIconIndirect(&icon_info);

  SelectObject(memory_dc, previous_font);
  SelectObject(memory_dc, previous_pen);
  SelectObject(memory_dc, previous_brush);
  SelectObject(memory_dc, previous_bitmap);
  DeleteObject(font);
  DeleteObject(badge_pen);
  DeleteObject(badge_brush);
  DeleteObject(color_bitmap);
  DeleteObject(mask_bitmap);
  DeleteDC(memory_dc);

  return icon;
}

void FlutterWindow::ClearOverlayIcon() {
  if (overlay_icon_ != nullptr) {
    DestroyIcon(overlay_icon_);
    overlay_icon_ = nullptr;
  }
}
