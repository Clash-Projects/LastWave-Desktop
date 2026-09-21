#include "yt_webview_guard.h"

#include <cstring>

#include <gtk/gtk.h>

// Must match CreateConfiguration(title:) in yt_web_login.dart (ASCII-only:
// the title is compared byte-wise here).
static constexpr const char* kYtWindowTitle = "LastWave YouTube Sign In";
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

static GtkWidget* find_yt_window() {
  GList* tops = gtk_window_list_toplevels();
  GtkWidget* found = nullptr;
  for (GList* l = tops; l != nullptr; l = l->next) {
    if (!GTK_IS_WINDOW(l->data)) {
      continue;
    }
    const gchar* title = gtk_window_get_title(GTK_WINDOW(l->data));
    if (title != nullptr && strcmp(title, kYtWindowTitle) == 0) {
      found = GTK_WIDGET(l->data);
      break;
    }
  }
  g_list_free(tops);
  return found;
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
