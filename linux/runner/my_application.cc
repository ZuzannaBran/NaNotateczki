#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* stylus_button_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static GdkDevice* source_device_for_event(GdkEvent* event) {
  GdkDevice* source_device = gdk_event_get_source_device(event);
  if (source_device == nullptr) {
    source_device = gdk_event_get_device(event);
  }
  return source_device;
}

static gboolean is_tablet_like_source(GdkInputSource source) {
  return source == GDK_SOURCE_PEN || source == GDK_SOURCE_ERASER ||
         source == GDK_SOURCE_TABLET_PAD;
}

static gboolean device_name_suggests_stylus(GdkDevice* device) {
  const gchar* name = gdk_device_get_name(device);
  if (name == nullptr) {
    return FALSE;
  }

  gchar* lower_name = g_utf8_strdown(name, -1);
  const gboolean result =
      g_strrstr(lower_name, "stylus") != nullptr ||
      g_strrstr(lower_name, "pen") != nullptr ||
      g_strrstr(lower_name, "tablet") != nullptr ||
      g_strrstr(lower_name, "wacom") != nullptr ||
      g_strrstr(lower_name, "dell") != nullptr;
  g_free(lower_name);
  return result;
}

static void send_stylus_button_state(MyApplication* self, gboolean pressed,
                                     gint code, const gchar* source) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "pressed", fl_value_new_bool(pressed));
  fl_value_set_string_take(args, "button", fl_value_new_int(code));
  fl_value_set_string_take(args, "source", fl_value_new_string(source));
  fl_method_channel_invoke_method(self->stylus_button_channel, "setPressed",
                                  args, nullptr, nullptr, nullptr);
}

static gboolean is_stylus_button_event(GdkEventButton* event) {
  GdkEvent* base_event = reinterpret_cast<GdkEvent*>(event);
  if (gdk_event_get_device_tool(base_event) != nullptr) {
    return event->button != GDK_BUTTON_PRIMARY;
  }

  GdkDevice* source_device = source_device_for_event(base_event);
  if (source_device == nullptr) {
    return FALSE;
  }

  const GdkInputSource source = gdk_device_get_source(source_device);
  return is_tablet_like_source(source) && event->button != GDK_BUTTON_PRIMARY;
}

static gboolean stylus_button_event_cb(GtkWidget* widget, GdkEventButton* event,
                                       gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->stylus_button_channel == nullptr ||
      !is_stylus_button_event(event)) {
    return FALSE;
  }

  const gboolean pressed = event->type == GDK_BUTTON_PRESS;
  if (!pressed && event->type != GDK_BUTTON_RELEASE) {
    return FALSE;
  }

  send_stylus_button_state(self, pressed, event->button, "button");
  return FALSE;
}

static gboolean is_stylus_key_event(GdkEventKey* event) {
  GdkEvent* base_event = reinterpret_cast<GdkEvent*>(event);
  if (gdk_event_get_device_tool(base_event) != nullptr) {
    return TRUE;
  }

  GdkDevice* source_device = source_device_for_event(base_event);
  if (source_device == nullptr) {
    return FALSE;
  }

  const GdkInputSource source = gdk_device_get_source(source_device);
  if (is_tablet_like_source(source)) {
    return TRUE;
  }

  return source == GDK_SOURCE_KEYBOARD &&
         device_name_suggests_stylus(source_device);
}

static gboolean stylus_key_event_cb(GtkWidget* widget, GdkEventKey* event,
                                    gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->stylus_button_channel == nullptr || !is_stylus_key_event(event)) {
    return FALSE;
  }

  const gboolean pressed = event->type == GDK_KEY_PRESS;
  if (!pressed && event->type != GDK_KEY_RELEASE) {
    return FALSE;
  }

  send_stylus_button_state(self, pressed, event->hardware_keycode, "key");
  return FALSE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "program");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "program");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  gtk_widget_add_events(GTK_WIDGET(view),
                        GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
                            GDK_KEY_PRESS_MASK | GDK_KEY_RELEASE_MASK |
                            GDK_PROXIMITY_IN_MASK | GDK_PROXIMITY_OUT_MASK);

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->stylus_button_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(engine), "nanotateczki/stylus_button",
      FL_METHOD_CODEC(codec));
  g_signal_connect(view, "button-press-event",
                   G_CALLBACK(stylus_button_event_cb), self);
  g_signal_connect(view, "button-release-event",
                   G_CALLBACK(stylus_button_event_cb), self);
  g_signal_connect(view, "key-press-event", G_CALLBACK(stylus_key_event_cb),
                   self);
  g_signal_connect(view, "key-release-event", G_CALLBACK(stylus_key_event_cb),
                   self);
  g_signal_connect(window, "key-press-event", G_CALLBACK(stylus_key_event_cb),
                   self);
  g_signal_connect(window, "key-release-event", G_CALLBACK(stylus_key_event_cb),
                   self);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_object(&self->stylus_button_channel);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
