// HttpStreamServer.mm — minimal HTTP server that streams H.264 access units to
// browsers, where WebCodecs decodes them. Application framing inside the HTTP
// (chunked) body: [1 byte type: 1=key,0=delta][4 byte BE length][Annex-B data].

#import "net/HttpStreamServer.h"
#import <pthread.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>

#define RCTL_MAX_CLIENTS 8

struct rctl_http_server {
    int listen_fd;
    int port;
    pthread_t thread;
    pthread_mutex_t mtx;
    int clients[RCTL_MAX_CLIENTS]; // stream subscriber fds (-1 = empty)
    uint8_t *keyframe;
    size_t keyframe_len;
    int orientation;
    rctl_reconfigure_cb recfg;
    void *recfg_ctx;
    rctl_input_cb input_cb;
    void *input_ctx;
    volatile bool running;
};

static char *read_file(const char *path, size_t *outLen) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return NULL; }
    char *b = (char *)malloc((size_t)n + 1);
    if (!b) { fclose(f); return NULL; }
    size_t rd = fread(b, 1, (size_t)n, f);
    fclose(f);
    b[rd] = 0;
    if (outLen) *outLen = rd;
    return b;
}

static const char *kHtml = R"HTML(<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>rctl</title>
<style>
  html,body{margin:0;height:100%;background:#000;color:#ddd;
    font-family:-apple-system,system-ui,sans-serif;overflow:hidden;
    -webkit-user-select:none;user-select:none}
  #stage{position:fixed;inset:0;display:flex;align-items:center;justify-content:center}
  canvas{transform-origin:center center}
  #hud{position:fixed;top:6px;left:8px;font-size:11px;opacity:.55;z-index:10}
  #bar{position:fixed;bottom:10px;left:50%;transform:translateX(-50%);z-index:10;
    display:flex;gap:6px;background:rgba(20,20,22,.55);padding:6px;border-radius:11px;
    -webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px)}
  #bar button{background:#2b2b2f;color:#eee;border:0;border-radius:8px;padding:7px 11px;font-size:12px}
  #bar button.on{background:#3478f6}
</style></head>
<body>
<div id="hud">rctl: connecting…</div>
<div id="stage"><canvas id="c"></canvas></div>
<div id="bar">
  <button data-q="hq" class="on">High</button>
  <button data-q="bal">Balanced</button>
  <button data-q="lat">Low latency</button>
</div>
<script>
const hud=document.getElementById('hud'),canvas=document.getElementById('c'),ctx=canvas.getContext('2d');
let dec=null,ts=0,frames=0,started=false,orient=1,codec='avc1.640033';
const DEG={1:0,2:180,3:-90,4:90};
function applyOrient(){
  const deg=DEG[orient]||0,cw=canvas.width||1,ch=canvas.height||1;
  const r90=(deg===90||deg===-90);
  const bbW=r90?ch:cw,bbH=r90?cw:ch;
  const sc=Math.min(innerWidth/bbW,innerHeight/bbH);
  canvas.style.transform=`rotate(${deg}deg) scale(${sc})`;
}
addEventListener('resize',applyOrient);
function codecFromAU(au){
  for(let i=0;i+8<au.length;i++){
    if(au[i]===0&&au[i+1]===0&&au[i+2]===0&&au[i+3]===1&&(au[i+4]&0x1f)===7){
      return 'avc1.'+[au[i+5],au[i+6],au[i+7]].map(x=>x.toString(16).padStart(2,'0')).join('');
    }
  }
  return null;
}
function mkdec(){
  if(dec){try{dec.close()}catch(e){}}
  dec=new VideoDecoder({
    output:f=>{const rs=(canvas.width!==f.displayWidth||canvas.height!==f.displayHeight);
      if(rs){canvas.width=f.displayWidth;canvas.height=f.displayHeight;}
      ctx.drawImage(f,0,0);f.close();frames++;if(rs)applyOrient();},
    error:e=>{hud.textContent='decoder error: '+e.message;started=false;dec=null;}
  });
  dec.configure({codec,optimizeForLatency:true});
}
setInterval(()=>{hud.textContent=`rctl — ${frames}f ${canvas.width}x${canvas.height} o=${orient} ${codec}`;},1000);
document.querySelectorAll('#bar button').forEach(b=>b.onclick=()=>{
  const q={hq:'scale=1.0&fps=30&bitrate=24000000',
           bal:'scale=0.75&fps=45&bitrate=14000000',
           lat:'scale=0.6&fps=60&bitrate=8000000'}[b.dataset.q];
  fetch('/config?'+q);
  document.querySelectorAll('#bar button').forEach(x=>x.classList.remove('on'));b.classList.add('on');
});
(async()=>{
  let resp;try{resp=await fetch('/stream');}catch(e){hud.textContent='fetch failed: '+e;return;}
  const reader=resp.body.getReader();let buf=new Uint8Array(0);
  for(;;){
    const r=await reader.read();if(r.done){hud.textContent='stream ended';break;}
    const nb=new Uint8Array(buf.length+r.value.length);nb.set(buf,0);nb.set(r.value,buf.length);buf=nb;
    for(;;){
      if(buf.length<5)break;
      const type=buf[0];
      const len=((buf[1]<<24)>>>0)+(buf[2]<<16)+(buf[3]<<8)+buf[4];
      if(buf.length<5+len)break;
      const data=buf.slice(5,5+len);buf=buf.subarray(5+len);
      if(type===2){if(data.length>=1){orient=data[0];applyOrient();}continue;}
      if(type===3){started=false;if(dec){try{dec.close()}catch(e){}}dec=null;continue;}
      const key=(type===1);
      if(!started){if(!key)continue;const cs=codecFromAU(data);if(cs)codec=cs;mkdec();started=true;}
      try{
        dec.decode(new EncodedVideoChunk({type:key?'key':'delta',timestamp:ts,data}));ts+=10000;
      }catch(e){hud.textContent='decode err: '+e.message;}
    }
  }
})();
</script></body></html>
)HTML";

static bool send_full(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t w = send(fd, p + off, len - off, MSG_NOSIGNAL);
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; return false; }
        off += (size_t)w;
    }
    return true;
}

// Send one access unit as a single HTTP chunk: "<hex>\r\n" + appframe + "\r\n".
static bool send_frame_chunk(int fd, uint8_t type, const uint8_t *data, size_t len) {
    char hdr[32];
    size_t af_len = 5 + len;
    int hl = snprintf(hdr, sizeof(hdr), "%zx\r\n", af_len);
    size_t total = (size_t)hl + af_len + 2;
    uint8_t *b = (uint8_t *)malloc(total);
    if (!b) return false;
    memcpy(b, hdr, hl);
    uint8_t *af = b + hl;
    af[0] = type;
    af[1] = (len >> 24) & 0xff; af[2] = (len >> 16) & 0xff;
    af[3] = (len >> 8) & 0xff;  af[4] = len & 0xff;
    if (len) memcpy(af + 5, data, len);
    b[total - 2] = '\r'; b[total - 1] = '\n';
    bool ok = send_full(fd, b, total);
    free(b);
    return ok;
}

static void send_text(int fd, const char *status, const char *ctype, const char *body) {
    char hdr[256];
    int n = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
        "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        status, ctype, strlen(body));
    send_full(fd, hdr, n);
    send_full(fd, body, strlen(body));
}

static void handle_client(rctl_http_server *s, int fd) {
    char req[2048];
    ssize_t n = recv(fd, req, sizeof(req) - 1, 0);
    if (n <= 0) { close(fd); return; }
    req[n] = 0;

    if (strncmp(req, "GET /stream", 11) == 0) {
        const char *h =
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
            "Transfer-Encoding: chunked\r\nCache-Control: no-cache\r\n"
            "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n";
        if (!send_full(fd, h, strlen(h))) { close(fd); return; }
        struct timeval tv = { 1, 0 }; // drop a stalled (e.g. dropped-Wi-Fi) client fast
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        pthread_mutex_lock(&s->mtx);
        if (s->keyframe) send_frame_chunk(fd, 1, s->keyframe, s->keyframe_len);
        { uint8_t ob = (uint8_t)s->orientation; send_frame_chunk(fd, 2, &ob, 1); }
        int slot = -1;
        for (int i = 0; i < RCTL_MAX_CLIENTS; i++) if (s->clients[i] < 0) { slot = i; break; }
        if (slot >= 0) s->clients[slot] = fd; else close(fd);
        pthread_mutex_unlock(&s->mtx);
        // keep fd open for streaming (pushed from rctl_http_push_au)
    } else if (strncmp(req, "GET /input", 10) == 0) {
        int phase = 0, id = 0; double x = 0, y = 0;
        char *p;
        if ((p = strstr(req, "phase="))) phase = atoi(p + 6);
        if ((p = strstr(req, "id=")))    id    = atoi(p + 3);
        if ((p = strstr(req, "x=")))     x     = atof(p + 2);
        if ((p = strstr(req, "y=")))     y     = atof(p + 2);
        pthread_mutex_lock(&s->mtx);
        rctl_input_cb cb = s->input_cb; void *cx = s->input_ctx;
        pthread_mutex_unlock(&s->mtx);
        if (cb) cb(cx, phase, id, x, y);
        send_text(fd, "200 OK", "text/plain", "ok");
        close(fd);
    } else if (strncmp(req, "GET /config", 11) == 0) {
        int fps = 30, br = 20000000; double sc = 1.0;
        char *p;
        if ((p = strstr(req, "fps=")))     fps = atoi(p + 4);
        if ((p = strstr(req, "scale=")))   sc  = atof(p + 6);
        if ((p = strstr(req, "bitrate="))) br  = atoi(p + 8);
        pthread_mutex_lock(&s->mtx);
        rctl_reconfigure_cb cb = s->recfg; void *cx = s->recfg_ctx;
        pthread_mutex_unlock(&s->mtx);
        fprintf(stderr, "[http] /config fps=%d scale=%.2f bitrate=%d\n", fps, sc, br);
        if (cb) cb(cx, fps, sc, br);
        send_text(fd, "200 OK", "text/plain", "ok");
        close(fd);
    } else if (strncmp(req, "GET /orient", 11) == 0) {
        char body[16];
        snprintf(body, sizeof(body), "%d", s->orientation);
        send_text(fd, "200 OK", "text/plain", body);
        close(fd);
    } else if (strncmp(req, "GET / ", 6) == 0 || strncmp(req, "GET /index", 10) == 0) {
        size_t hlen = 0;
        char *html = read_file("/var/mobile/rctl/index.html", &hlen);
        send_text(fd, "200 OK", "text/html; charset=utf-8", html ? html : kHtml);
        free(html);
        close(fd);
    } else {
        send_text(fd, "404 Not Found", "text/plain", "not found");
        close(fd);
    }
}

static void *accept_loop(void *arg) {
    rctl_http_server *s = (rctl_http_server *)arg;
    while (s->running) {
        struct sockaddr_in ca; socklen_t cl = sizeof(ca);
        int fd = accept(s->listen_fd, (struct sockaddr *)&ca, &cl);
        if (fd < 0) { if (!s->running) break; continue; }
        int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        handle_client(s, fd);
    }
    return NULL;
}

rctl_http_server *rctl_http_start(int port) {
    signal(SIGPIPE, SIG_IGN);
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { fprintf(stderr, "[http] socket failed\n"); return NULL; }
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[http] bind %d failed: %s\n", port, strerror(errno));
        close(lfd); return NULL;
    }
    if (listen(lfd, 8) < 0) { fprintf(stderr, "[http] listen failed\n"); close(lfd); return NULL; }

    rctl_http_server *s = (rctl_http_server *)calloc(1, sizeof(rctl_http_server));
    s->listen_fd = lfd; s->port = port; s->running = true; s->orientation = 1;
    for (int i = 0; i < RCTL_MAX_CLIENTS; i++) s->clients[i] = -1;
    pthread_mutex_init(&s->mtx, NULL);
    pthread_create(&s->thread, NULL, accept_loop, s);
    fprintf(stderr, "[http] serving on 0.0.0.0:%d\n", port);
    return s;
}

// Broadcast a typed frame to all subscribers (caller holds the mutex).
static void broadcast_locked(rctl_http_server *s, uint8_t type, const uint8_t *data, size_t len) {
    for (int i = 0; i < RCTL_MAX_CLIENTS; i++) {
        int fd = s->clients[i];
        if (fd < 0) continue;
        if (!send_frame_chunk(fd, type, data, len)) { close(fd); s->clients[i] = -1; }
    }
}

void rctl_http_push_au(rctl_http_server *s, const uint8_t *data, size_t len, bool keyframe) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    if (keyframe) {
        uint8_t *k = (uint8_t *)malloc(len);
        if (k) { memcpy(k, data, len); free(s->keyframe); s->keyframe = k; s->keyframe_len = len; }
    }
    broadcast_locked(s, keyframe ? 1 : 0, data, len);
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_set_orientation(rctl_http_server *s, int orientation) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    if (orientation != s->orientation) {
        s->orientation = orientation;
        uint8_t b = (uint8_t)orientation;
        broadcast_locked(s, 2, &b, 1);
    }
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_signal_reset(rctl_http_server *s) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    free(s->keyframe); s->keyframe = NULL; s->keyframe_len = 0;
    broadcast_locked(s, 3, NULL, 0);
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_set_reconfigure(rctl_http_server *s, rctl_reconfigure_cb cb, void *ctx) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    s->recfg = cb; s->recfg_ctx = ctx;
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_set_input(rctl_http_server *s, rctl_input_cb cb, void *ctx) {
    if (!s) return;
    pthread_mutex_lock(&s->mtx);
    s->input_cb = cb; s->input_ctx = ctx;
    pthread_mutex_unlock(&s->mtx);
}

void rctl_http_stop(rctl_http_server *s) {
    if (!s) return;
    s->running = false;
    close(s->listen_fd);
    pthread_mutex_lock(&s->mtx);
    for (int i = 0; i < RCTL_MAX_CLIENTS; i++) if (s->clients[i] >= 0) close(s->clients[i]);
    free(s->keyframe);
    pthread_mutex_unlock(&s->mtx);
    free(s);
}
