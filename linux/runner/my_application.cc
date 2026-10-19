#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void focus_flutter_view(GtkWindow* window, GtkWidget* view) {
  if (window == nullptr || view == nullptr) {
    return;
  }

  if (!gtk_widget_get_can_focus(view)) {
    gtk_widget_set_can_focus(view, TRUE);
  }

  gtk_window_set_focus(window, view);
  gtk_widget_grab_focus(view);
}

static void on_window_show(GtkWidget* widget, gpointer user_data) {
  focus_flutter_view(GTK_WINDOW(widget), GTK_WIDGET(user_data));
}

static gboolean on_window_focus_in_event(GtkWidget* widget,
                                         GdkEventFocus* event,
                                         gpointer user_data) {
  (void)event;
  focus_flutter_view(GTK_WINDOW(widget), GTK_WIDGET(user_data));
  return FALSE;
}

static void on_window_is_active_changed(GObject* object,
                                        GParamSpec* pspec,
                                        gpointer user_data) {
  (void)pspec;
  GtkWindow* window = GTK_WINDOW(object);
  if (!gtk_window_is_active(window)) {
    return;
  }
  focus_flutter_view(window, GTK_WIDGET(user_data));
}

static gboolean on_view_button_press_event(GtkWidget* widget,
                                           GdkEventButton* event,
                                           gpointer user_data) {
  (void)event;
  focus_flutter_view(GTK_WINDOW(user_data), widget);
  return FALSE;
}

// 首帧到达后显示顶层窗口
static void first_frame_cb(MyApplication* self, FlView* view) {
  (void)self;
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // 单实例：已有窗口就把它提到前面。浏览器授权登录回跳（discourse://auth_redirect）、
  // fluxdo:// 链接都会再启动一次本程序，第二个进程只把命令行转给这里（见下方
  // local_command_line），不另开窗口。
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

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
    gtk_header_bar_set_title(header_bar, "cfluxdo");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "cfluxdo");
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
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // 先 realize 让 Flutter 开始渲染，首帧画出来再显示窗口，避免黑屏闪一下。
  // （上游由 window_manager 在 Dart 侧恢复窗口状态后再显示；cfluxdo 已去掉该依赖）
  gtk_widget_show(GTK_WIDGET(view));
  gtk_widget_realize(GTK_WIDGET(view));
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);

  gtk_widget_add_events(GTK_WIDGET(view), GDK_BUTTON_PRESS_MASK);
  g_signal_connect(window, "show", G_CALLBACK(on_window_show), view);
  g_signal_connect(window,
                   "focus-in-event",
                   G_CALLBACK(on_window_focus_in_event),
                   view);
  g_signal_connect(window,
                   "notify::is-active",
                   G_CALLBACK(on_window_is_active_changed),
                   view);
  g_signal_connect(
      view, "button-press-event", G_CALLBACK(on_view_button_press_event), window);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  focus_flutter_view(window, GTK_WIDGET(view));
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

  // 返回 FALSE 让 GApplication 接着处理命令行：主实例在本地发出 command-line 信号，
  // 后启动的实例把命令行经 D-Bus 转给主实例后退出。gtk 插件（app_links 的 Linux 实现
  // 靠它）监听这个信号，把链接交给 Dart。上游模板返回 TRUE 且不唯一，结果每次回跳都
  // 新开一个进程，链接谁也收不到。
  return FALSE;
}

// Implements GApplication::command_line.
// gtk 插件连在 command-line 信号上并先于这里返回；插件没注册时兜底，避免 GLib 报
// 「声称处理命令行却没实现」并以 1 退出。
static int my_application_command_line(GApplication* application,
                                       GApplicationCommandLine* command_line) {
  (void)application;
  (void)command_line;
  return 0;
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
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
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

  return MY_APPLICATION(g_object_new(
      my_application_get_type(), "application-id", APPLICATION_ID, "flags",
      G_APPLICATION_HANDLES_COMMAND_LINE | G_APPLICATION_HANDLES_OPEN,
      nullptr));
}
