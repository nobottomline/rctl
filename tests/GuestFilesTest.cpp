#include "security/GuestFiles.h"
#include <cassert>
#include <filesystem>
#include <fstream>
int main() {
    char path[] = "/tmp/rctl-guest-files.XXXXXX";
    assert(mkdtemp(path));
    std::filesystem::path root(path);
    std::filesystem::create_directory(root/"nested");
    std::ofstream(root/"nested"/"safe") << "test";
    std::filesystem::create_symlink("/etc",root/"escape");
    std::filesystem::create_symlink("/etc/passwd",root/"link");
    rctl::GuestFiles files(::open(path,O_RDONLY|O_DIRECTORY));
    int fd = files.open("nested/safe"); assert(fd>=0); close(fd);
    for (const auto &p: {"../x","/etc/passwd","nested/../safe","nested//safe","nested/",".hidden","escape/passwd","link"}) {
        bool denied=false; try { close(files.open(p)); } catch (...) { denied=true; } assert(denied);
    }
    std::filesystem::create_hard_link(root/"nested"/"safe",root/"hard");
    bool denied=false; try { close(files.open("hard")); } catch (...) { denied=true; } assert(denied);
    std::filesystem::remove(root/"hard"); files.remove("nested/safe");
    assert(!std::filesystem::exists(root/"nested"/"safe"));
    std::filesystem::remove_all(root);
}
