#include "include/tray_manager/tray_manager_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#ifdef HAVE_AYATANA
#include <libayatana-appindicator/app-indicator.h>
#else
#include <libappindicator/app-indicator.h>
#endif
#include <algorithm>
#include <cstring>
#include <map>

#define TRAY_MANAGER_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), tray_manager_plugin_get_type(), \
                              TrayManagerPlugin))

TrayManagerPlugin* plugin_instance;

GtkStatusIcon* tray_icon = nullptr;
GtkWidget* tray_menu = nullptr;

struct _TrayManagerPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  FlMethodChannel* channel;
};

G_DEFINE_TYPE(TrayManagerPlugin, tray_manager_plugin, g_object_get_type())

// Gets the window being controlled.
GtkWindow* get_window(TrayManagerPlugin* self) {
  FlView* view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr)
    return nullptr;

  return GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void emit_tray_event(const char* event_name) {
  fl_method_channel_invoke_method(plugin_instance->channel, event_name, nullptr,
                                  nullptr, nullptr, nullptr);
}

void _on_activate(GtkMenuItem* item, gpointer user_data) {
  gint id = GPOINTER_TO_INT(user_data);

  g_autoptr(FlValue) result_data = fl_value_new_map();
  fl_value_set_string_take(result_data, "id", fl_value_new_int(id));
  fl_method_channel_invoke_method(plugin_instance->channel,
                                  "onTrayMenuItemClick", result_data, nullptr,
                                  nullptr, nullptr);
}

GtkWidget* _create_menu(FlValue* args) {
  FlValue* items_value = fl_value_lookup_string(args, "items");

  GtkWidget* menu = gtk_menu_new();
  for (gint i = 0; i < fl_value_get_length(items_value); i++) {
    FlValue* item_value = fl_value_get_list_value(items_value, i);
    const int id = fl_value_get_int(fl_value_lookup_string(item_value, "id"));
    const char* type =
        fl_value_get_string(fl_value_lookup_string(item_value, "type"));
    const char* label =
        fl_value_get_string(fl_value_lookup_string(item_value, "label"));
    const bool disabled =
        fl_value_get_bool(fl_value_lookup_string(item_value, "disabled"));

    gint item_id = id;

    if (strcmp(type, "separator") == 0) {
      gtk_menu_shell_append(GTK_MENU_SHELL(menu),
                            gtk_separator_menu_item_new());
    } else {
      GtkWidget* item = gtk_menu_item_new_with_label(label);

      if (disabled) {
        gtk_widget_set_sensitive(item, FALSE);
      }

      if (strcmp(type, "checkbox") == 0) {
        item = gtk_check_menu_item_new_with_label(label);
        const auto checked_value =
            fl_value_lookup_string(item_value, "checked");
        if (checked_value != nullptr) {
          const auto checked = fl_value_get_bool(checked_value);
          gtk_check_menu_item_set_active((GtkCheckMenuItem*)item, checked);
        }
      } else if (strcmp(type, "submenu") == 0) {
        GtkWidget* sub_menu =
            _create_menu(fl_value_lookup_string(item_value, "submenu"));
        gtk_menu_item_set_submenu(GTK_MENU_ITEM(item), sub_menu);
      }

      g_signal_connect(G_OBJECT(item), "activate", G_CALLBACK(_on_activate),
                       GINT_TO_POINTER(item_id));

      gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    }
  }
  return menu;
}

static void popup_tray_menu(guint button, guint activate_time) {
  if (tray_icon == nullptr || tray_menu == nullptr) {
    return;
  }

  gtk_widget_show_all(tray_menu);
  gtk_menu_popup(GTK_MENU(tray_menu), nullptr, nullptr,
                 gtk_status_icon_position_menu, tray_icon, button,
                 activate_time);
}

static void on_status_icon_activate(GtkStatusIcon* status_icon,
                                    gpointer user_data) {
  emit_tray_event("onTrayIconMouseDown");
  emit_tray_event("onTrayIconMouseUp");
}

static void on_status_icon_popup_menu(GtkStatusIcon* status_icon, guint button,
                                      guint activate_time, gpointer user_data) {
  emit_tray_event("onTrayIconRightMouseDown");
  popup_tray_menu(button, activate_time);
  emit_tray_event("onTrayIconRightMouseUp");
}

static FlMethodResponse* destroy(TrayManagerPlugin* self, FlValue* args) {
  if (tray_icon != nullptr) {
    gtk_status_icon_set_visible(tray_icon, FALSE);
    g_clear_object(&tray_icon);
  }
  if (tray_menu != nullptr) {
    gtk_widget_destroy(tray_menu);
    tray_menu = nullptr;
  }
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* set_icon(TrayManagerPlugin* self, FlValue* args) {
  const char* icon_path =
      fl_value_get_string(fl_value_lookup_string(args, "iconPath"));

  if (tray_menu == nullptr) {
    tray_menu = gtk_menu_new();
  }

  if (tray_icon == nullptr) {
    tray_icon = gtk_status_icon_new_from_file(icon_path);
    g_signal_connect(G_OBJECT(tray_icon), "activate",
                     G_CALLBACK(on_status_icon_activate), self);
    g_signal_connect(G_OBJECT(tray_icon), "popup-menu",
                     G_CALLBACK(on_status_icon_popup_menu), self);
  } else {
    gtk_status_icon_set_from_file(tray_icon, icon_path);
  }

  gtk_status_icon_set_visible(tray_icon, TRUE);

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* set_title(TrayManagerPlugin* self, FlValue* args) {
  const char* title =
      fl_value_get_string(fl_value_lookup_string(args, "title"));

  if (tray_icon != nullptr) {
    gtk_status_icon_set_title(tray_icon, title);
  }

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* set_tool_tip(TrayManagerPlugin* self, FlValue* args) {
  const char* tool_tip =
      fl_value_get_string(fl_value_lookup_string(args, "toolTip"));

  if (tray_icon != nullptr) {
    gtk_status_icon_set_tooltip_text(tray_icon, tool_tip);
  }

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* set_context_menu(TrayManagerPlugin* self,
                                          FlValue* args) {
  if (tray_menu != nullptr) {
    gtk_widget_destroy(tray_menu);
  }
  tray_menu = _create_menu(fl_value_lookup_string(args, "menu"));
  gtk_widget_show_all(tray_menu);

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* pop_up_context_menu(TrayManagerPlugin* self,
                                             FlValue* args) {
  popup_tray_menu(0, gtk_get_current_event_time());
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

// Called when a method call is received from Flutter.
static void tray_manager_plugin_handle_method_call(TrayManagerPlugin* self,
                                                   FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "destroy") == 0) {
    response = destroy(self, args);
  } else if (strcmp(method, "setIcon") == 0) {
    response = set_icon(self, args);
  } else if (strcmp(method, "setToolTip") == 0) {
    response = set_tool_tip(self, args);
  } else if (strcmp(method, "setTitle") == 0) {
    response = set_title(self, args);
  } else if (strcmp(method, "setContextMenu") == 0) {
    response = set_context_menu(self, args);
  } else if (strcmp(method, "popUpContextMenu") == 0) {
    response = pop_up_context_menu(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void tray_manager_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(tray_manager_plugin_parent_class)->dispose(object);
}

static void tray_manager_plugin_class_init(TrayManagerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = tray_manager_plugin_dispose;
}

static void tray_manager_plugin_init(TrayManagerPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  TrayManagerPlugin* plugin = TRAY_MANAGER_PLUGIN(user_data);
  tray_manager_plugin_handle_method_call(plugin, method_call);
}

void tray_manager_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  TrayManagerPlugin* plugin = TRAY_MANAGER_PLUGIN(
      g_object_new(tray_manager_plugin_get_type(), nullptr));

  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "tray_manager", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  plugin_instance = plugin;

  g_object_unref(plugin);
}
