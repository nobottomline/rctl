#include "net/CameraIngest.h"
#include <cassert>
#include <cstdlib>
#include <cstddef>
#include <unistd.h>
#include <sys/wait.h>
extern "C" void rctl_webrtc_push_camera_au(const uint8_t*,size_t,bool,uint64_t) {}
int main() {
    const char *a="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",*b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    auto generation=rctl_camera_set_enabled(true,1,10,1500000);
    char *state=rctl_camera_agent_state_owned(a,0,getpid());assert(state);free(state);
    state=rctl_camera_agent_state_owned(b,0,getpid());assert(state);free(state);
    assert(!rctl_camera_generation_retired(generation));
    rctl_camera_set_active(false);
    state=rctl_camera_agent_state_owned(a,generation,getpid());assert(state);free(state);
    assert(!rctl_camera_generation_retired(generation));
    state=rctl_camera_agent_state_owned(b,generation,getpid());assert(state);free(state);
    assert(rctl_camera_generation_retired(generation));
    auto replacement=rctl_camera_set_enabled(true,2,10,1500000);
    state=rctl_camera_agent_state_owned(a,generation,getpid());assert(state);free(state);
    assert(!rctl_camera_generation_retired(replacement));
    state=rctl_camera_agent_state_owned(a,generation,getpid());assert(state);free(state);
    assert(!rctl_camera_generation_retired(replacement));
    assert(!rctl_camera_agent_state_owned("caller",replacement,getpid()));
    rctl_camera_set_active(false);
    state=rctl_camera_agent_state_owned(a,replacement,getpid());assert(state);free(state);
    assert(rctl_camera_generation_retired(replacement));
    int fence[2];assert(pipe(fence)==0);
    auto child=fork();assert(child>=0);
    if(child==0){close(fence[1]);char byte;read(fence[0],&byte,1);_exit(0);}
    close(fence[0]);auto exited=rctl_camera_set_enabled(true,1,10,1500000);
    state=rctl_camera_agent_state_owned(b,0,child);assert(state);free(state);
    rctl_camera_set_active(false);assert(!rctl_camera_generation_retired(exited));
    close(fence[1]);int status;assert(waitpid(child,&status,0)==child);
    assert(rctl_camera_generation_retired(exited));
}
