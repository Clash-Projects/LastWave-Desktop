#include "yt_webview_guard.h"

#include <cstring>

#include <gtk/gtk.h>

// Must match CreateConfiguration(title:) in yt_web_login.dart (ASCII-only:
// the title is compared byte-wise here).
static constexpr const char* kYtWindowTitle = "LastWave YouTube Sign In";
// Must match CreateConfiguration(title:) in potoken_engine.dart.
static constexpr const char* kBotGuardTitle = "LastWave BotGuard";
// Marker so the delete-event blocker is attached exactly once per window.
static constexpr const char* kArmedKey = "lastwave-yt-guarded";

static FlMethodChannel* g_channel = nullptr;

// X pressed (or any delete-event): hide instead of destroying. Returning
// TRUE stops GTK's default handler, so the WebKit window — and its EGL
// context — stays alive and no destroy signal ever fires.
static gboolean on_yt_delete_event(GtkWidget* widget, GdkEvent* /*event*/,
                                   gpointer /*user_data*/) {
  gtk_widget_hide(widget);
  return TRUE;
}

static GtkWidget* find_window_by_title(const char* title) {
  GList* tops = gtk_window_list_toplevels();
  GtkWidget* found = nullptr;
  for (GList* l = tops; l != nullptr; l = l->next) {
    if (!GTK_IS_WINDOW(l->data)) {
      continue;
    }
    const gchar* t = gtk_window_get_title(GTK_WINDOW(l->data));
    if (t != nullptr && strcmp(t, title) == 0) {
      found = GTK_WIDGET(l->data);
      break;
    }
  }
  g_list_free(tops);
  return found;
}

static GtkWidget* find_yt_window() {
  return find_window_by_title(kYtWindowTitle);
}

static GtkWidget* find_botguard_window() {
  return find_window_by_title(kBotGuardTitle);
}

static void arm_delete_blocker(GtkWidget* window) {
  if (g_object_get_data(G_OBJECT(window), kArmedKey) != nullptr) {
    return;
  }
  g_object_set_data(G_OBJECT(window), kArmedKey, GINT_TO_POINTER(1));
  g_signal_connect(window, "delete-event", G_CALLBACK(on_yt_delete_event),
                   nullptr);
}

static void handle_method_call(FlMethodChannel* /*channel*/,
                               FlMethodCall* method_call,
                               gpointer /*user_data*/) {
  const gchar* method = fl_method_call_get_name(method_call);
  GtkWidget* window = find_yt_window();
  if (strcmp(method, "hide") == 0) {
    if (window != nullptr) {
      arm_delete_blocker(window);
      gtk_widget_hide(window);
    }
    g_autoptr(FlValue) result = fl_value_new_bool(window != nullptr);
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }
  if (strcmp(method, "show") == 0) {
    if (window != nullptr) {
      arm_delete_blocker(window);
      gtk_widget_show(window);
      gtk_window_present(GTK_WINDOW(window));
    }
    g_autoptr(FlValue) result = fl_value_new_bool(window != nullptr);
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }
  // BotGuard poToken window (potoken_engine.dart): same upstream destroy
  // bug as the sign-in window, plus no visibility/move API on Linux, so
  // it must never be destroyed either — hide and reuse for app lifetime.
  // The Dart side never calls close() on Linux; these are the hide path
  // (called right after create, since plugin hide is a no-op) and a
  // show escape hatch for diagnostics.
  if (strcmp(method, "hideBotGuard") == 0) {
    GtkWidget* bg = find_botguard_window();
    if (bg != nullptr) {
      arm_delete_blocker(bg);
      gtk_widget_hide(bg);
    }
    g_autoptr(FlValue) result = fl_value_new_bool(bg != nullptr);
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }
  if (strcmp(method, "showBotGuard") == 0) {
    GtkWidget* bg = find_botguard_window();
    if (bg != nullptr) {
      arm_delete_blocker(bg);
      gtk_widget_show(bg);
      gtk_window_present(GTK_WINDOW(bg));
    }
    g_autoptr(FlValue) result = fl_value_new_bool(bg != nullptr);
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

void yt_webview_guard_register(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "LastWaveYtWebviewGuard");
  // Owned by the registrar; kept alive for process lifetime.
  g_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "lastwave/yt_webview",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, handle_method_call,
                                            nullptr, nullptr);
}
