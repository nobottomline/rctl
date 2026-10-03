#include "../core/net/VirtualMicServer.mm"
#include <cassert>
#include <cerrno>
int main() {
    int16_t pcm[4]={1,2,3,4};
    rctl_vmic_set_route(RCTL_TALK_SPEAKER);
    rctl_vmic_push(pcm,4);assert(g_queue.empty());
    rctl_vmic_push_routed(pcm,4);assert(g_queue.size()==1);
    assert(rctl_vmic_route()==RCTL_TALK_SPEAKER);
    auto delayed=std::move(g_queue.front());g_queue.pop_front();
    int sockets[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)==0);
    g_clients.push_back(sockets[0]);broadcast(delayed.samples,delayed.generation);
    uint32_t length;assert(read(sockets[1],&length,4)==4&&ntohl(length)==sizeof pcm);
    int16_t received[4];assert(read(sockets[1],received,sizeof received)==sizeof received&&received[3]==4);
    rctl_vmic_push_routed(pcm,4);rctl_vmic_clear();assert(g_queue.empty()&&g_clients.empty());
    char byte;assert(read(sockets[1],&byte,1)==0);close(sockets[1]);
    assert(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)==0);g_clients.push_back(sockets[0]);
    broadcast(delayed.samples,delayed.generation);
    assert(recv(sockets[1],&byte,1,MSG_DONTWAIT)<0&&(errno==EAGAIN||errno==EWOULDBLOCK));
    rctl_vmic_clear();close(sockets[1]);
}
