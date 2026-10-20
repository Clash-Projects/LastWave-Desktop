#include "my_application.h"

#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--no-enable-impeller") == 0 ||
        strcmp(argv[i], "--disable-impeller") == 0 ||
        strcmp(argv[i], "--enable-software-rendering") == 0 ||
        strcmp(argv[i], "--software") == 0) {
      setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
      setenv("LASTWAVE_DISABLE_IMPELLER", "1", 1);
      setenv("FLUTTER_ENABLE_IMPELLER", "0", 1);
      break;
    }
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
