#include "linux_environment.h"
#include "my_application.h"

int main(int argc, char** argv) {
  configure_linux_environment();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
