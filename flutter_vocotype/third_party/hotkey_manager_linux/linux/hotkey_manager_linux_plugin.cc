#include "include/hotkey_manager_linux/hotkey_manager_linux_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gdk/gdkkeysyms.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstring>

#include <keybinder.h>

#include <algorithm>
#include <map>
#include <string>
#include <vector>

#include "hotkey_manager_linux_plugin_private.h"

#ifdef GDK_WINDOWING_X11
#include <X11/Xlib.h>
#include <gdk/gdkx.h>
#endif

#define HOTKEY_MANAGER_LINUX_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), hotkey_manager_linux_plugin_get_type(), \
                              HotkeyManagerLinuxPlugin))

std::map<std::string, std::string> hotkey_id_map;
std::map<std::string, guint> hotkey_keyup_watch_id_map;
FlEventChannel* event_channel;

struct KeyUpWatchContext {
  std::string identifier;
  guint keyval = 0;
};

struct _HotkeyManagerLinuxPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(HotkeyManagerLinuxPlugin,
              hotkey_manager_linux_plugin,
              g_object_get_type())

void send_hotkey_event(const char* type, const char* identifier) {
  g_autoptr(FlValue) event_data = fl_value_new_map();
  fl_value_set_string_take(event_data, "identifier",
                           fl_value_new_string(identifier));

  FlValue* event = fl_value_new_map();
  fl_value_set_string_take(event, "type", fl_value_new_string(type));
  fl_value_set_string_take(event, "data", event_data);

  fl_event_channel_send(event_channel, event, nullptr, nullptr);
}

void clear_keyup_watch(const std::string& identifier) {
  auto it = hotkey_keyup_watch_id_map.find(identifier);
  if (it == hotkey_keyup_watch_id_map.end())
    return;

  g_source_remove(it->second);
  hotkey_keyup_watch_id_map.erase(it);
}

void clear_all_keyup_watches() {
  for (auto it = hotkey_keyup_watch_id_map.begin();
       it != hotkey_keyup_watch_id_map.end(); ++it) {
    g_source_remove(it->second);
  }
  hotkey_keyup_watch_id_map.clear();
}

void destroy_keyup_watch_context(gpointer user_data) {
  delete static_cast<KeyUpWatchContext*>(user_data);
}

gboolean is_keyval_pressed(guint keyval) {
#ifdef GDK_WINDOWING_X11
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == NULL || !GDK_IS_X11_DISPLAY(gdk_display))
    return FALSE;

  Display* xdisplay = gdk_x11_display_get_xdisplay(gdk_display);
  if (xdisplay == NULL)
    return FALSE;

  KeyCode keycode = XKeysymToKeycode(xdisplay, keyval);
  if (keycode == 0)
    return FALSE;

  char keys[32];
  XQueryKeymap(xdisplay, keys);
  return (keys[keycode / 8] & (1 << (keycode % 8))) != 0;
#else
  (void)keyval;
  return FALSE;
#endif
}

gboolean poll_key_up(gpointer user_data) {
  auto* context = static_cast<KeyUpWatchContext*>(user_data);
  if (is_keyval_pressed(context->keyval))
    return G_SOURCE_CONTINUE;

  send_hotkey_event("onKeyUp", context->identifier.c_str());
  hotkey_keyup_watch_id_map.erase(context->identifier);
  return G_SOURCE_REMOVE;
}

void start_keyup_watch(const char* identifier, const char* keystring) {
  guint keyval = 0;
  GdkModifierType modifiers = static_cast<GdkModifierType>(0);
  gtk_accelerator_parse(keystring, &keyval, &modifiers);
  if (keyval == 0)
    return;

  std::string id = identifier;
  clear_keyup_watch(id);

  auto* context = new KeyUpWatchContext();
  context->identifier = id;
  context->keyval = keyval;

  const guint source_id = g_timeout_add_full(
      G_PRIORITY_DEFAULT,
      15,
      poll_key_up,
      context,
      destroy_keyup_watch_context);
  hotkey_keyup_watch_id_map[id] = source_id;
}

void handle_key_down(const char* keystring, void* user_data) {
  const char* identifier = "";

  std::string val = keystring;
  auto result = std::find_if(hotkey_id_map.begin(), hotkey_id_map.end(),
                             [val](const auto& e) { return e.second == val; });

  if (result != hotkey_id_map.end())
    identifier = result->first.c_str();

  send_hotkey_event("onKeyDown", identifier);
  if (identifier[0] != '\0')
    start_keyup_watch(identifier, keystring);
}

guint get_mods(const std::vector<std::string>& modifiers) {
  guint mods = 0;
  for (int i = 0; i < modifiers.size(); i++) {
    guint mod = 0;
    if (modifiers[i] == "alt")
      mod = GDK_MOD1_MASK;
    else if (modifiers[i] == "capsLock")
      mod = GDK_LOCK_MASK;
    else if (modifiers[i] == "control")
      mod = GDK_CONTROL_MASK;
    else if (modifiers[i] == "meta")
      mod = GDK_META_MASK;
    else if (modifiers[i] == "shift")
      mod = GDK_SHIFT_MASK;
    mods = mods | mod;
  }
  return mods;
}

guint normalize_key_code(guint key_code) {
  // Flutter's GTK key map may resolve F1-F4 to KP_F1-KP_F4 first.
  // Keybinder fails to bind those keypad function aliases on some setups.
  switch (key_code) {
    case GDK_KEY_KP_F1:
      return GDK_KEY_F1;
    case GDK_KEY_KP_F2:
      return GDK_KEY_F2;
    case GDK_KEY_KP_F3:
      return GDK_KEY_F3;
    case GDK_KEY_KP_F4:
      return GDK_KEY_F4;
    default:
      return key_code;
  }
}

static FlMethodResponse* hkm_register(_HotkeyManagerLinuxPlugin* self,
                                      FlValue* args) {
  FlValue* modifiers_value = fl_value_lookup_string(args, "modifiers");

  const char* identifier =
      fl_value_get_string(fl_value_lookup_string(args, "identifier"));
  const int key_code =
      fl_value_get_int(fl_value_lookup_string(args, "keyCode"));
  std::vector<std::string> modifiers;
  for (gint i = 0; i < fl_value_get_length(modifiers_value); i++) {
    std::string keyModifier =
        fl_value_get_string(fl_value_get_list_value(modifiers_value, i));
    modifiers.push_back(keyModifier);
  }

  const guint normalized_key_code = normalize_key_code(key_code);
  const char* keystring = gtk_accelerator_name(
      normalized_key_code, (GdkModifierType)get_mods(modifiers));

  hotkey_id_map.insert(
      std::pair<std::string, std::string>(identifier, keystring));

  keybinder_init();
  const gboolean is_bound = keybinder_bind(keystring, handle_key_down, NULL);
  if (!is_bound) {
    g_warning("Binding '%s' failed!", keystring);
  }

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* hkm_unregister(_HotkeyManagerLinuxPlugin* self,
                                        FlValue* args) {
  const char* identifier =
      fl_value_get_string(fl_value_lookup_string(args, "identifier"));
  const char* keystring = "";

  std::string val = identifier;
  auto result = std::find_if(hotkey_id_map.begin(), hotkey_id_map.end(),
                             [val](const auto& e) { return e.first == val; });

  if (result != hotkey_id_map.end())
    keystring = result->second.c_str();

  keybinder_unbind(keystring, handle_key_down);
  clear_keyup_watch(identifier);
  hotkey_id_map.erase(identifier);

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* hkm_unregister_all(_HotkeyManagerLinuxPlugin* self,
                                            FlValue* args) {
  for (std::map<std::string, std::string>::iterator it = hotkey_id_map.begin();
       it != hotkey_id_map.end(); ++it) {
    std::string identifier = it->first;
    const char* keystring = it->second.c_str();
    keybinder_unbind(keystring, handle_key_down);
  }

  clear_all_keyup_watches();
  hotkey_id_map.clear();

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

// Called when a method call is received from Flutter.
static void hotkey_manager_linux_plugin_handle_method_call(
    HotkeyManagerLinuxPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "register") == 0) {
    response = hkm_register(self, args);
  } else if (strcmp(method, "unregister") == 0) {
    response = hkm_unregister(self, args);
  } else if (strcmp(method, "unregisterAll") == 0) {
    response = hkm_unregister_all(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar* version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void hotkey_manager_linux_plugin_dispose(GObject* object) {
  clear_all_keyup_watches();
  g_clear_object(&event_channel);
  G_OBJECT_CLASS(hotkey_manager_linux_plugin_parent_class)->dispose(object);
}

static void hotkey_manager_linux_plugin_class_init(
    HotkeyManagerLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = hotkey_manager_linux_plugin_dispose;
}

static void hotkey_manager_linux_plugin_init(HotkeyManagerLinuxPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  HotkeyManagerLinuxPlugin* plugin = HOTKEY_MANAGER_LINUX_PLUGIN(user_data);
  hotkey_manager_linux_plugin_handle_method_call(plugin, method_call);
}

void hotkey_manager_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  HotkeyManagerLinuxPlugin* plugin = HOTKEY_MANAGER_LINUX_PLUGIN(
      g_object_new(hotkey_manager_linux_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "dev.leanflutter.plugins/hotkey_manager", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_autoptr(FlStandardMethodCodec) event_codec = fl_standard_method_codec_new();
  event_channel =
      fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
                           "dev.leanflutter.plugins/hotkey_manager_event",
                           FL_METHOD_CODEC(event_codec));

  g_object_unref(plugin);
}
