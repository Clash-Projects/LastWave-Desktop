#ifndef FLUTTER_YT_WEBVIEW_GUARD_H_
#define FLUTTER_YT_WEBVIEW_GUARD_H_

#include <flutter_linux/flutter_linux.h>

// Registers the "lastwave/yt_webview" method channel (hide/show) and
// X-close interception for the YouTube sign-in WebView window.
//
// Background: upstream desktop_webview_window 0.3.0 implements neither
// setWebviewWindowVisibility nor moveWebviewWindow on Linux, and its
// Gtk "destroy" handler segfaults (use-after-free) on every webview
// close. So YtWebLogin never destroys the window — this guard hides it
// instead, and converts the window's own X button into a hide.
void yt_webview_guard_register(FlView* view);

#endif  // FLUTTER_YT_WEBVIEW_GUARD_H_
