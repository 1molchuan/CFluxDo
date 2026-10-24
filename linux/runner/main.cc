#include "my_application.h"
#include <cerrno>
#include <cstring>
#include <unistd.h>

int main(int argc, char** argv) {
  const char* restart_geometry = nullptr;
  if (argc >= 3 && strcmp(argv[1], "--fluxdo-site-restart") == 0) {
    restart_geometry = argv[2];
    // 父进程持有写端，直到整个进程退出才关闭；不要提前启动新 Flutter 引擎。
    char byte;
    ssize_t count;
    do {
      count = read(STDIN_FILENO, &byte, 1);
    } while (count > 0 || (count < 0 && errno == EINTR));
    if (count < 0) {
      g_printerr("站点切换失败：无法等待旧进程退出。\n");
      return 1;
    }
    close(STDIN_FILENO);
    for (int index = 3; index < argc; ++index) {
      argv[index - 2] = argv[index];
    }
    argc -= 2;
    argv[argc] = nullptr;
  }
  g_autoptr(MyApplication) app = my_application_new();
  if (restart_geometry != nullptr) {
    g_object_set_data_full(G_OBJECT(app), "site-restart-geometry",
                           g_strdup(restart_geometry), g_free);
  }
  return g_application_run(G_APPLICATION(app), argc, argv);
}
