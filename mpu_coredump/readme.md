
# 前言
   2020年的时候， 公司有一个内部的叫mpu的服务音视频服务，因为存在随机奔溃的情况，不敢大规模铺开。负责的cpp的开发的同学对此束手无策，找了一段时间也没有找到原因。
   刚好我这边刚好合并到新的业务线， 就顺便伸出了援手，花了一周多的时间，从0接触开始，靠gdb追踪coredump文件和人肉分析源码，终于诊断出问题。 这篇文档记录了这个问题解决的过程，本来是发到公司内部的乐享文档的，但腾讯乐享文档收费后， 公司要关闭这个服务。
   我觉得这个文档还是可以作为一个用gdb配查coredump问题的教程记录一下的，便搬到 github上。 
   由于2022年，mpu服务已经下线，因此也不存安全问题，顺便也把coredump文件也上传上来。
      
   
# 问题描述
mpu服务器在高峰期会崩溃，这种奔溃是随机的，奔溃后产生coredump文件。

# profile 信息
怀疑是内存问题导致，采用 valgrind 进行内存检测。
执行命令:  
```bash
/bin/valgrind --track-origins=yes --gen-suppressions=all --suppressions=/data/dubbo/blitz/mps/gw.supp --log-file=/data/dubbo/blitz/mps/valgrind_mpu_8500 /data/dubbo/blitz/mps/blitz_mpu 20000 8500
```

结果信息 见附件 gw.supp

# 结果信息分析

经统计， 内存泄漏报告中有三类错误。

## 第一类错误 

### 报告描述：

```

# Syscall param fcntl(fd) contains uninitialised byte(s)
#    at 0x5ABC614: fcntl (in /usr/lib64/libpthread-2.17.so)
#    by 0x5294F7: blitz::mpu::TransportModule::PrepareMediaSocket(int) (transport.cc:59)
#    by 0x529F12: blitz::mpu::TransportModule::Start(unsigned short) (transport.cc:250)
#    by 0x544C5C: blitz::mpu::MpuCore::Serve(unsigned short) (core.cc:90)
#    by 0x54F352: main (main.cc:18)
#  Uninitialised value was created by a heap allocation
#    at 0x4C284C3: operator new(unsigned long) (vg_replace_malloc.c:344)
#    by 0x544E39: blitz::mpu::MpuCore::MpuCore(unsigned int, unsigned short) (core.cc:94)
#    by 0x54F33D: main (main.cc:17)
# 

```

### 原因分析:
已经确定原因。
问题行  by 0x5294F7: blitz::mpu::TransportModule::PrepareMediaSocket(int) (transport.cc:59) 

对应代码
```cpp
      int save_flags = fcntl(_mpsSocket, F_GETFL, 0);
            BLITZ_I("Set udp socket to no blocking mode");
            ret = fcntl(_mediaSocket, F_SETFL, save_flags | O_NONBLOCK);
            if (ret == -1) {
                BLITZ_E("set udp socket blocking error code %d", errno);
                return -1;
            }
```

原因是 误用变量 _mpsSocket ，实际应该是_mediaSocket ，
_mpsSocket 对应的是一个fd，fcntl(_mpsSocket, F_GETFL, 0) 变更未知fd的阻塞模式。
局部int 未初始化值为随机数，事实上会是栈位置的残留值。
这个错误，应该只是让mediaSocket设置非预期。 不一定会导致崩溃。

### 修改方案或建议: 
1. 修改为正确的变量。
2. 第一次使用fcntl 获取fd状态也应该判断返回值。并给出错误。   最好调试一下， save_flags 为非0的时候， 的设置是否有会出错，或者出问题。




## 第二类错误

### 现象描述
```
# Syscall param socketcall.sendto(msg) points to uninitialised byte(s)
#    at 0x5ABCA43: __sendto_nocancel (in /usr/lib64/libpthread-2.17.so)
#    by 0x52A57F: blitz::mpu::TransportModule::SendMedia(ObjectPtr<blitz::mpu::TransportPacket>&) (transport.cc:331)
#    by 0x52A7D1: blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&) (transport.cc:366)
#    by 0x4F7121: blitz::mpu::BlitzConnection::SendBlitzPacket(ObjectPtr<blitz::mpu::BlitzPacket>&) (blitz_connection.cc:26)
#    by 0x51F7B8: blitz::mpu::UserConnection::HandlePacketConnectedState(ObjectPtr<blitz::mpu::BlitzPacket>&) (user_connection.cc:178)
#    by 0x51EFE7: blitz::mpu::UserConnection::OnBlitzPacketParsed(ObjectPtr<blitz::mpu::BlitzPacket>&) (user_connection.cc:72)
#    by 0x4F724B: blitz::mpu::BlitzConnection::OnNetPacketReceived(ObjectPtr<blitz::mpu::TransportPacket>&) (blitz_connection.cc:40)
#    by 0x4FC77A: blitz::mpu::ConnectionModule::OnNetPacketReceived(ObjectPtr<blitz::mpu::TransportPacket>&) (connection.cc:49)
#    by 0x529E56: blitz::mpu::TransportModule::HandleMediaRecv() (transport.cc:239)
#    by 0x52A401: blitz::mpu::TransportModule::Start(unsigned short) (transport.cc:306)
#    by 0x544C5C: blitz::mpu::MpuCore::Serve(unsigned short) (core.cc:90)
#    by 0x54F352: main (main.cc:18)
#  Address 0x636097c is 12 bytes inside a block of size 3,000 alloc'd
#    at 0x4C28B68: operator new[](unsigned long) (vg_replace_malloc.c:433)
#    by 0x50F4BD: blitz::mpu::BlitzBuffer::BlitzBuffer(ObjectPool<blitz::mpu::BlitzBuffer>*) (mpu_types.h:190)
#    by 0x510C88: ObjectPool<blitz::mpu::BlitzBuffer>::get() (pooled_object.h:23)
#    by 0x51F0F3: blitz::mpu::UserConnection::returnAccessResult(blitz::mpu::AccessResult) (user_connection.cc:94)
#    by 0x51F2F2: blitz::mpu::UserConnection::HandlePacketConnectingState(ObjectPtr<blitz::mpu::BlitzPacket>&) (user_connection.cc:112)
#    by 0x51F077: blitz::mpu::UserConnection::HandlePacketNoneState(ObjectPtr<blitz::mpu::BlitzPacket>&) (user_connection.cc:84)
#    by 0x51EFBD: blitz::mpu::UserConnection::OnBlitzPacketParsed(ObjectPtr<blitz::mpu::BlitzPacket>&) (user_connection.cc:66)
#    by 0x4F724B: blitz::mpu::BlitzConnection::OnNetPacketReceived(ObjectPtr<blitz::mpu::TransportPacket>&) (blitz_connection.cc:40)
#    by 0x4FC8B1: blitz::mpu::ConnectionModule::OnNetPacketReceived(ObjectPtr<blitz::mpu::TransportPacket>&) (connection.cc:65)
#    by 0x529E56: blitz::mpu::TransportModule::HandleMediaRecv() (transport.cc:239)
#    by 0x52A401: blitz::mpu::TransportModule::Start(unsigned short) (transport.cc:306)
#    by 0x544C5C: blitz::mpu::MpuCore::Serve(unsigned short) (core.cc:90)
#  Uninitialised value was created by a heap allocation
#    at 0x4C28B68: operator new[](unsigned long) (vg_replace_malloc.c:433)
#    by 0x50F4BD: blitz::mpu::BlitzBuffer::BlitzBuffer(ObjectPool<blitz::mpu::BlitzBuffer>*) (mpu_types.h:190)
#    by 0x510C88: ObjectPool<blitz::mpu::BlitzBuffer>::get() (pooled_object.h:23)
#    by 0x51F0F3: blitz::mpu::UserConnection::returnAccessResult(blitz::mpu::AccessResult) (user_connection.cc:94)
#    by 0x51F2F2: blitz::mpu::UserConnection::HandlePacketConnectingState(ObjectPtr<blitz::mpu::BlitzPacket>&) (user_connection.cc:112)
#    by 0x51F077: blitz::mpu::UserConnection::HandlePacketNoneState(ObjectPtr<blitz::mpu::BlitzPacket>&) (user_connection.cc:84)
#    by 0x51EFBD: blitz::mpu::UserConnection::OnBlitzPacketParsed(ObjectPtr<blitz::mpu::BlitzPacket>&) (user_connection.cc:66)
#    by 0x4F724B: blitz::mpu::BlitzConnection::OnNetPacketReceived(ObjectPtr<blitz::mpu::TransportPacket>&) (blitz_connection.cc:40)
#    by 0x4FC8B1: blitz::mpu::ConnectionModule::OnNetPacketReceived(ObjectPtr<blitz::mpu::TransportPacket>&) (connection.cc:65)
#    by 0x529E56: blitz::mpu::TransportModule::HandleMediaRecv() (transport.cc:239)
#    by 0x52A401: blitz::mpu::TransportModule::Start(unsigned short) (transport.cc:306)
#    by 0x544C5C: blitz::mpu::MpuCore::Serve(unsigned short) (core.cc:90)
# 
```

### 原因分析
对应的代码:
    by 0x52A57F: blitz::mpu::TransportModule::SendMedia(ObjectPtr<blitz::mpu::TransportPacket>&) (transport.cc:331)

```cpp
        int TransportModule::SendMedia(TransportPacket::Ptr &packet)
        {
            struct sockaddr_in toaddr;
            toaddr.sin_family = AF_INET;
            toaddr.sin_addr.s_addr = htonl(packet->ip);
            toaddr.sin_port = htons(packet->port);
			
line:331            int ret = (int) sendto(_mediaSocket, packet->buffer->data, packet->len, 0, (const sockaddr *) &toaddr, sizeof(toaddr));

            if(ret <= 0) {
                _sendErrorCounts++;
                BLITZ_E("send error count %lld,last ip %u,port %d,len %d,error %d", _sendErrorCounts, packet->ip,
                        (int) packet->port, (int) packet->len, errno);
            }
            return ret;

        }
```

by 0x50F4BD: blitz::mpu::BlitzBuffer::BlitzBuffer(ObjectPool<blitz::mpu::BlitzBuffer>*) (mpu_types.h:190)

```cpp
        class BlitzBuffer : public PoolAbleObject<BlitzBuffer> {
        public:
            typedef ObjectPtr<BlitzBuffer> Ptr;
        public:
            //缓存数据总长度;
            uint32_t len;
            uint8_t *data;

            BlitzBuffer(ObjectPool<BlitzBuffer> *pool) : PoolAbleObject(pool) {
line 190：                data = new uint8_t[MAX_PACKET_SIZE];
                this->len = MAX_PACKET_SIZE;
            }

            ~BlitzBuffer() {
                BLITZ_D("blitz buffer delete");
                delete[](data);
            }

            virtual void onIdle() override {
                // BLITZ_D("blitz buffer idle");
            }
        };
```

 (transport.cc:331) 里面 用到了几个参数，packet 在之前已经有使用， 所以可以排除packet 本身的未初始化问题， 但是packet 里的buffer的data ，可能存在未初始化问题，联系建议的origin，推断出 (mpu_types.h:190) 的 data 没有初始化被检测到。

### 修改方案或者建议
(mpu_types.h:190)  
```cpp
data = new uint8_t[MAX_PACKET_SIZE]; 
改成 
//注意这个性能开销可能会很大，不要轻易上生产
data = new uint8_t[MAX_PACKET_SIZE]();
```




## 第三类错误
应该是发生在 对象池里， 这类代码很多。 做了一个统计分类 主要有三种。
```bash
grep "SendMpuRequest" gw.supp | sort|uniq
```
```
   fun:_ZN5blitz3mpu15LocalConnection14SendMpuRequestERNS0_5proto10MpuRequestE
#    by 0x50E0CC: blitz::mpu::LocalConnection::SendMpuRequest(blitz::mpu::proto::MpuRequest&) (local_connection.cc:321)
#    by 0x50E122: blitz::mpu::LocalConnection::SendMpuRequest(blitz::mpu::proto::MpuRequest&) (local_connection.cc:325)
#    by 0x50E16B: blitz::mpu::LocalConnection::SendMpuRequest(blitz::mpu::proto::MpuRequest&) (local_connection.cc:328)

```


### 现象描述:

```
# Conditional jump or move depends on uninitialised value(s)
#    at 0x4F0ED9F: google::protobuf::MessageLite::SerializePartialToArray(void*, int) const (message_lite.cc:333)
#    by 0x50E0CC: blitz::mpu::LocalConnection::SendMpuRequest(blitz::mpu::proto::MpuRequest&) (local_connection.cc:321)
#    by 0x4FE413: blitz::mpu::ConnectionModule::OnTimer(blitz::mpu::TimerTask*) (connection.cc:438)
#    by 0x54528A: blitz::mpu::MpuCore::OnTimer(unsigned long) (core.cc:138)
#    by 0x52A2D5: blitz::mpu::TransportModule::Start(unsigned short) (transport.cc:293)
#    by 0x544C5C: blitz::mpu::MpuCore::Serve(unsigned short) (core.cc:90)
#    by 0x54F352: main (main.cc:18)
#  Uninitialised value was created by a heap allocation
#    at 0x4C284C3: operator new(unsigned long) (vg_replace_malloc.c:344)
#    by 0x4FC30B: blitz::mpu::ConnectionModule::ConnectionModule(blitz::mpu::MpuCore*, unsigned short, unsigned int) (connection.cc:24)
#    by 0x544E7D: blitz::mpu::MpuCore::MpuCore(unsigned int, unsigned short) (core.cc:95)
#    by 0x54F33D: main (main.cc:17)
# 
```

```
# Conditional jump or move depends on uninitialised value(s)
#    at 0x50F717: google::protobuf::internal::ToIntSize(unsigned long) (generated_message_util.h:212)
#    by 0x50F7D8: google::protobuf::MessageLite::ByteSize() const (message_lite.h:252)
#    by 0x50E122: blitz::mpu::LocalConnection::SendMpuRequest(blitz::mpu::proto::MpuRequest&) (local_connection.cc:325)
#    by 0x4FE413: blitz::mpu::ConnectionModule::OnTimer(blitz::mpu::TimerTask*) (connection.cc:438)
#    by 0x54528A: blitz::mpu::MpuCore::OnTimer(unsigned long) (core.cc:138)
#    by 0x52A2D5: blitz::mpu::TransportModule::Start(unsigned short) (transport.cc:293)
#    by 0x544C5C: blitz::mpu::MpuCore::Serve(unsigned short) (core.cc:90)
#    by 0x54F352: main (main.cc:18)
#  Uninitialised value was created by a heap allocation
#    at 0x4C284C3: operator new(unsigned long) (vg_replace_malloc.c:344)
#    by 0x4FC30B: blitz::mpu::ConnectionModule::ConnectionModule(blitz::mpu::MpuCore*, unsigned short, unsigned int) (connection.cc:24)
#    by 0x544E7D: blitz::mpu::MpuCore::MpuCore(unsigned int, unsigned short) (core.cc:95)
#    by 0x54F33D: main (main.cc:17)
# 
```

```
# Conditional jump or move depends on uninitialised value(s)
#    at 0x4C2C6EF: is_overlap (vg_replace_strmem.c:131)
#    by 0x4C2C6EF: memcpy@@GLIBC_2.14 (vg_replace_strmem.c:1035)
#    by 0x52A771: blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&) (transport.cc:357)
#    by 0x4FD9A8: blitz::mpu::ConnectionModule::SendTransportPacket(ObjectPtr<blitz::mpu::TransportPacket>&) (connection.cc:229)
#    by 0x50E16B: blitz::mpu::LocalConnection::SendMpuRequest(blitz::mpu::proto::MpuRequest&) (local_connection.cc:328)
#    by 0x4FE413: blitz::mpu::ConnectionModule::OnTimer(blitz::mpu::TimerTask*) (connection.cc:438)
#    by 0x54528A: blitz::mpu::MpuCore::OnTimer(unsigned long) (core.cc:138)
#    by 0x52A2D5: blitz::mpu::TransportModule::Start(unsigned short) (transport.cc:293)
#    by 0x544C5C: blitz::mpu::MpuCore::Serve(unsigned short) (core.cc:90)
#    by 0x54F352: main (main.cc:18)
#  Uninitialised value was created by a heap allocation
#    at 0x4C284C3: operator new(unsigned long) (vg_replace_malloc.c:344)
#    by 0x4FC30B: blitz::mpu::ConnectionModule::ConnectionModule(blitz::mpu::MpuCore*, unsigned short, unsigned int) (connection.cc:24)
#    by 0x544E7D: blitz::mpu::MpuCore::MpuCore(unsigned int, unsigned short) (core.cc:95)
#    by 0x54F33D: main (main.cc:17)
```

### 原因分析
未明，里面对对象池的操作比较繁多，很可能在此发生问题。
需要进一步结合coredump 数据分析看看

### 修改方案或者建议:
1. 先修正第一个和第二个valgrind的 错误，再压测一次。
2. 修改出一个测试版，追踪 缓冲池对象的 构造和析构 以及reset方法，看看其中有无错误。


# coredump 文件分析

## 调试环境
需要安装一些依赖包，未明确。
使用已经建立好的测试环境。193.112.64.179 (video-test01) 
进入奔溃现场，coredump 镜像对应源文件版本不太正确， 暂时不关联源文件分析。
```bash
cd /data/dubbo/biltz/mps
gdb blitz_mpu ./linc_test/valgrind_mpu_8500.core.16079
```
## 分析所在的崩溃点
从崩溃现场最近的函数开始追踪代码 和数据。 先确定崩溃点，然后确定崩溃点附近的栈帧以及对应的内存数据。

### 通过where 和 info line 确定位置
```
(gdb) where
#0  0x000000000052a723 in blitz::mpu::TransportModule::SendPacket (this=0x62e42a0, packet=...) at /mnt/hgfs/blitz/blitz_mpu/modules/transport/transport.cc:356
#1  0x00000000004fd9cd in blitz::mpu::ConnectionModule::SendTransportPacket (this=0x62e4910, packet=...) at /mnt/hgfs/blitz/blitz_mpu/modules/connection/connection.cc:229
#2  0x000000000050e457 in blitz::mpu::LocalConnection::SendMpuResponse (this=0x62e4e50, initRequest=..., response=...) at /mnt/hgfs/blitz/blitz_mpu/modules/connection/local_connection.cc:356
#3  0x000000000050cdc9 in blitz::mpu::LocalConnection::handleRequest (this=0x62e4e50, request=...) at /mnt/hgfs/blitz/blitz_mpu/modules/connection/local_connection.cc:135
#4  0x000000000050d02a in blitz::mpu::LocalConnection::OnNetPacketReceived (this=0x62e4e50, packet=...) at /mnt/hgfs/blitz/blitz_mpu/modules/connection/local_connection.cc:153
#5  0x00000000004fc77b in blitz::mpu::ConnectionModule::OnNetPacketReceived (this=0x62e4910, packet=...) at /mnt/hgfs/blitz/blitz_mpu/modules/connection/connection.cc:49
#6  0x0000000000529b40 in blitz::mpu::TransportModule::HandleMpsRecv (this=0x62e42a0) at /mnt/hgfs/blitz/blitz_mpu/modules/transport/transport.cc:175
#7  0x000000000052a357 in blitz::mpu::TransportModule::Start (this=0x62e42a0, port=8500) at /mnt/hgfs/blitz/blitz_mpu/modules/transport/transport.cc:296
#8  0x0000000000544c81 in blitz::mpu::MpuCore::Serve (this=0x1fff000aa0, port=8500) at /mnt/hgfs/blitz/blitz_mpu/core.cc:90
#9  0x000000000054f377 in main (argc=3, argv=0x1fff000d68) at /mnt/hgfs/blitz/blitz_mpu/main.cc:18
(gdb) info line
Line number 0 is out of range for "/mnt/hgfs/blitz/blitz_mpu/modules/transport/transport.cc".

```

### 观测 参数和本地变量

```
(gdb) info args
this = 0x62e42a0
packet = @0x1fff000660: {_ptr = 0x6353d70}
(gdb) info local
buff = 0x6354ac0
sendToMps = true
```

### 观测 寄存器和栈帧 
```
(gdb) info registers 
rax            0x373436315f69616e	3977863956557029742
rbx            0xc	12
rcx            0x6697070	107573360
rdx            0x18	24
rsi            0x6697070	107573360       //重要
rdi            0x6354ac0	104155840       //重要
rbp            0x1fff0005b0	0x1fff0005b0    //重要 栈基
rsp            0x1fff000580	0x1fff000580    //重要，当前栈顶
r8             0x4	4
r9             0x62e52dc	103699164
r10            0x0	0
r11            0x8	8
r12            0x4f6ec0	5205696
r13            0x1fff000d60	137422179680
r14            0x0	0
r15            0x0	0
rip            0x52a723	0x52a723 <blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&)+217>//重要
eflags         0x0	[ ]
cs             0x0	0
ss             0x0	0
ds             0x0	0
es             0x0	0
fs             0x0	0
gs             0x0	0


(gdb) info frame
//当前栈帧地址
Stack level 0, frame at 0x1fff0005c0:
 rip = 0x52a723 in blitz::mpu::TransportModule::SendPacket  //当前指令地址 (/mnt/hgfs/blitz/blitz_mpu/modules/transport/transport.cc:356); saved rip 0x4fd9cd //返回的指令地址
 called by frame at 0x1fff0005e0  //调用者栈帧，中间的gap就是 参数/返回值 重叠窗口。
 source language c++.
 Arglist at 0x1fff0005b0, args: this=0x62e42a0, packet=...   //参数列表地址 
 Locals at 0x1fff0005b0, Previous frame's sp is 0x1fff0005c0 //局部变量地址，它与参数/返回值都是重叠一段空间的。
 Saved registers:
  rbx at 0x1fff0005a0, rbp at 0x1fff0005b0, r12 at 0x1fff0005a8, rip at 0x1fff0005b8
```

查看帧栈信息
```
(gdb) x/40xg 0x1fff000520
0x1fff000520:	0x0000001fff000550	0x000000000052ad6a
0x1fff000530:	0x0000000006697070	0x00000000062e42d0
0x1fff000540:	0x0000000006697070	0x0000000006697070
0x1fff000550:	0x0000001fff000570	0x000000000052aaca
0x1fff000560:	0x0000000006697070	0x0000000006354ac0
0x1fff000570:	0x0000001fff0005b0	0x000000000052a723
0x1fff000580:	0x0000001fff000660	0x00000000062e42a0x
0x1fff000590:	0x0000000006354ac0	0x0100000100000064
0x1fff0005a0:	0x000000000000000c	0x00000000004f6ec0
0x1fff0005b0:	0x0000001fff0005d0	0x00000000004fd9cd  <== 当前栈顶指针，紧跟其后的是返回地址0x04fd9cd,栈由高向低增长
0x1fff0005c0:	0x0000001fff000660	0x00000000062e4910  
0x1fff0005d0:	0x0000001fff000680	0x000000000050e457
0x1fff0005e0:	0x0000001fff000630	0x0000001fff0006a0  <== 上个栈顶指针
0x1fff0005f0:	0x0000000006697190	0x00000000062e4e50
0x1fff000600:	0x0000000000589090	0x0000000000000000
0x1fff000610:	0x0000000c00000006	0x0000000000000000
0x1fff000620:	0x00000000066a6b20	0x0000000000000002
0x1fff000630:	0x0000000000589090	0x0000000000000000
0x1fff000640:	0x0000000000000006	0x0000000000000000
0x1fff000650:	0x00000000066a6ba0	0x0000000000000002

```

### 从崩溃点最近的函数 开始排查
源代码
```cpp
        int TransportModule::SendPacket(TransportPacket::Ptr& packet) {

            bool sendToMps = (packet->ip == _mpsIpHost) && (packet->port == _mpsPort);
            if (sendToMps)
            {
                //tcp nonblocking send
                BlitzTcpBuffer* buff = NULL;
                if (_idleTcpBuffer.size() == 0)
                {
                    buff = new BlitzTcpBuffer(MAX_TCP_BUFFER_SIZE);
                }
                else
                {
                    buff = _idleTcpBuffer.front();
                    _idleTcpBuffer.pop_front();
                }
line 356               *((uint16_t*)(buff->buff->data)) = htons(packet->len);
                memcpy(buff->buff->data+2, packet->buffer->data, packet->len);
                buff->startPos = 0;
                buff->totalLen = packet->len+2;
                _usingTcpBuffer.push_back(buff);
                return HandleMpsWrite();

            }
            else
            {
                if (SendMedia(packet) <= 0) {
                    //try one time
                    if (errno == EWOULDBLOCK) {
                        SendMedia(packet);
                    }
                }
            }
            return 0;
        }
```

```
(gdb) disassemble blitz::mpu::TransportModule::SendPacket
Dump of assembler code for function blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&):
   0x000000000052a64a <+0>:	push   %rbp                
   0x000000000052a64b <+1>:	mov    %rsp,%rbp          
   0x000000000052a64e <+4>:	push   %r12             //这个是什么值?
   0x000000000052a650 <+6>:	push   %rbx             //这个是什么值?
   0x000000000052a651 <+7>:	sub    $0x20,%rsp     //申请变量空间   32个字节 
   0x000000000052a655 <+11>:	mov    %rdi,-0x28(%rbp)     // this 指针
   0x000000000052a659 <+15>:	mov    %rsi,-0x30(%rbp)     // packet 这个引用， 传进来的是 packet 的地址
   0x000000000052a65d <+19>:	mov    -0x30(%rbp),%rax 
   0x000000000052a661 <+23>:	mov    %rax,%rdi        
   // 得到 *packet,也即 packet的实例， 而这个实例是一个 指针  --> eax
   0x000000000052a664 <+26>:	callq  0x4f84a2 <ObjectPtr<blitz::mpu::TransportPacket>::operator->()>     
   // ip的地址  8 虚表 + 8 pool * + 4 refcount + 2 len + 2 port = 24  对齐方式是 4字节。 如果是8字节，则应该是 28
   0x000000000052a669 <+31>:	mov    0x18(%rax),%edx    // packet->ip   => edx
   0x000000000052a66c <+34>:	mov    -0x28(%rbp),%rax   // this
// _mpsIpHost地址   8虚表 + 8 mupcore* + 8 sink* +4 _mediaSocket + 4 mpsSocket + (1 running + 3) + 4 mpsPort = 40
   0x000000000052a670 <+38>:	mov    0x28(%rax),%eax    // this->_mpsIpHost
   0x000000000052a673 <+41>:	cmp    %eax,%edx
   0x000000000052a675 <+43>:	jne    0x52a69c   <blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&)+82>
   0x000000000052a677 <+45>:	mov    -0x30(%rbp),%rax
   0x000000000052a67b <+49>:	mov    %rax,%rdi   
   0x000000000052a67e <+52>:	callq  0x4f84a2 <ObjectPtr<blitz::mpu::TransportPacket>::operator->()> 
   0x000000000052a683 <+57>:	movzwl 0x16(%rax),%eax     // packet->port  => eax
   0x000000000052a687 <+61>:	movzwl %ax,%edx 
   0x000000000052a68a <+64>:	mov    -0x28(%rbp),%rax  
   0x000000000052a68e <+68>:	mov    0x24(%rax),%eax      //this  -> _mpsPort
   0x000000000052a691 <+71>:	cmp    %eax,%edx   
   0x000000000052a693 <+73>:	jne    0x52a69c  
   <blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&)+82>
   0x000000000052a695 <+75>:	mov    $0x1,%eax
   0x000000000052a69a <+80>:	jmp    0x52a6a1  <blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&)+87>
   0x000000000052a69c <+82>:	mov    $0x0,%eax
   0x000000000052a6a1 <+87>:	mov    %al,-0x11(%rbp)     // 
   0x000000000052a6a4 <+90>:	cmpb   $0x0,-0x11(%rbp)    // 
   0x000000000052a6a8 <+94>:	je     0x52a7e3   // if false goto  0x52a7e3 <blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&)+409>
   0x000000000052a6ae <+100>:	movq   $0x0,-0x20(%rbp)     //buff  => -0x20(%rbp)
   0x000000000052a6b6 <+108>:	mov    -0x28(%rbp),%rax     // this
   0x000000000052a6ba <+112>:	add    $0x30,%rax           // this -> _idleTcpBuffer
   0x000000000052a6be <+116>:	mov    %rax,%rdi
   0x000000000052a6c1 <+119>:	callq  0x52aa3c <std::list<blitz::mpu::TransportModule::BlitzTcpBuffer*, std::allocator<blitz::mpu::TransportModule::BlitzTcpBuffer*> >::size() const>
   0x000000000052a6c6 <+124>:	test   %rax,%rax  // (_idleTcpBuffer.size() == 0) 时设置 zf标志位为1
   0x000000000052a6c9 <+127>:	sete   %al       // 如果 zf标志位为 1 设置  al 为 1，否则为0
   0x000000000052a6cc <+130>:	test   %al,%al   //如果 al 为0 ，设置标志位为1
   0x000000000052a6ce <+132>:	je     0x52a6f0   // 相当于 !(_idleTcpBuffer.size() == 0)时跳转 <blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&)+166>
   0x000000000052a6d0 <+134>:	mov    $0x10,%edi
   0x000000000052a6d5 <+139>:	callq  0x4f6a80 <_Znwm@plt>
   0x000000000052a6da <+144>:	mov    %rax,%rbx
   0x000000000052a6dd <+147>:	mov    $0x4e20,%esi
   0x000000000052a6e2 <+152>:	mov    %rbx,%rdi
   0x000000000052a6e5 <+155>:	callq  0x52a996 <blitz::mpu::TransportModule::BlitzTcpBuffer::BlitzTcpBuffer(int)>
   0x000000000052a6ea <+160>:	mov    %rbx,-0x20(%rbp)
   0x000000000052a6ee <+164>:	jmp    0x52a717 <blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&)+205>
   0x000000000052a6f0 <+166>:	mov    -0x28(%rbp),%rax 
   0x000000000052a6f4 <+170>:	add    $0x30,%rax
   0x000000000052a6f8 <+174>:	mov    %rax,%rdi
   0x000000000052a6fb <+177>:	callq  0x52aa76 <std::list<blitz::mpu::TransportModule::BlitzTcpBuffer*, std::allocator<blitz::mpu::TransportModule::BlitzTcpBuffer*> >::front()>
   0x000000000052a700 <+182>:	mov    (%rax),%rax
   0x000000000052a703 <+185>:	mov    %rax,-0x20(%rbp)   // buff = _idleTcpBuffer.front() 存入 -0x20(%rbp)
   0x000000000052a707 <+189>:	mov    -0x28(%rbp),%rax   // this
   0x000000000052a70b <+193>:	add    $0x30,%rax         // this -> _idleTcpBuffer => rax
   0x000000000052a70f <+197>:	mov    %rax,%rdi          // this -> _idleTcpBuffer => rdi
   0x000000000052a712 <+200>:	callq  0x52aaa0 <std::list<blitz::mpu::TransportModule::BlitzTcpBuffer*, std::allocator<blitz::mpu::TransportModule::BlitzTcpBuffer*> >::pop_front()>  //_idleTcpBuffer.pop_front()
   0x000000000052a717 <+205>:	mov    -0x20(%rbp),%rax  // buff --> %rax
   0x000000000052a71b <+209>:	mov    %rax,%rdi
   0x000000000052a71e <+212>:	callq  0x4f839c <ObjectPtr<blitz::mpu::BlitzBuffer>::operator->()>
=> 0x000000000052a723 <+217>:	mov    0x18(%rax),%rbx    <== 崩溃点
   0x000000000052a727 <+221>:	mov    -0x30(%rbp),%rax
   0x000000000052a72b <+225>:	mov    %rax,%rdi
   0x000000000052a72e <+228>:	callq  0x4f84a2 <ObjectPtr<blitz::mpu::TransportPacket>::operator->()>
   0x000000000052a733 <+233>:	movzwl 0x14(%rax),%eax
   0x000000000052a737 <+237>:	movzwl %ax,%eax
   0x000000000052a73a <+240>:	mov    %eax,%edi
   0x000000000052a73c <+242>:	callq  0x4f66c0 <htons@plt>
   0x000000000052a741 <+247>:	mov    %ax,(%rbx)
   0x000000000052a744 <+250>:	mov    -0x30(%rbp),%rax
   0x000000000052a748 <+254>:	mov    %rax,%rdi
   0x000000000052a74b <+257>:	callq  0x4f84a2 <ObjectPtr<blitz::mpu::TransportPacket>::operator->()>
   0x000000000052a750 <+262>:	movzwl 0x14(%rax),%eax
   0x000000000052a754 <+266>:	movzwl %ax,%r12d
   0x000000000052a758 <+270>:	mov    -0x30(%rbp),%rax
   0x000000000052a75c <+274>:	mov    %rax,%rdi
   0x000000000052a75f <+277>:	callq  0x4f84a2 <ObjectPtr<blitz::mpu::TransportPacket>::operator->()>
   0x000000000052a764 <+282>:	add    $0x20,%rax
   0x000000000052a768 <+286>:	mov    %rax,%rdi
   0x000000000052a76b <+289>:	callq  0x4f839c <ObjectPtr<blitz::mpu::BlitzBuffer>::operator->()>
   0x000000000052a770 <+294>:	mov    0x18(%rax),%rbx
   0x000000000052a774 <+298>:	mov    -0x20(%rbp),%rax
   0x000000000052a778 <+302>:	mov    %rax,%rdi
   0x000000000052a77b <+305>:	callq  0x4f839c <ObjectPtr<blitz::mpu::BlitzBuffer>::operator->()>
   0x000000000052a780 <+310>:	mov    0x18(%rax),%rax
   0x000000000052a784 <+314>:	add    $0x2,%rax
   0x000000000052a788 <+318>:	mov    %r12,%rdx
   0x000000000052a78b <+321>:	mov    %rbx,%rsi
   0x000000000052a78e <+324>:	mov    %rax,%rdi
   0x000000000052a791 <+327>:	callq  0x4f69d0 <memcpy@plt>
   0x000000000052a796 <+332>:	mov    -0x20(%rbp),%rax
   0x000000000052a79a <+336>:	movl   $0x0,0xc(%rax)
   0x000000000052a7a1 <+343>:	mov    -0x20(%rbp),%rbx
   0x000000000052a7a5 <+347>:	mov    -0x30(%rbp),%rax
   0x000000000052a7a9 <+351>:	mov    %rax,%rdi
   0x000000000052a7ac <+354>:	callq  0x4f84a2 <ObjectPtr<blitz::mpu::TransportPacket>::operator->()>
   0x000000000052a7b1 <+359>:	movzwl 0x14(%rax),%eax
   0x000000000052a7b5 <+363>:	movzwl %ax,%eax
   0x000000000052a7b8 <+366>:	add    $0x2,%eax
   0x000000000052a7bb <+369>:	mov    %eax,0x8(%rbx)
   0x000000000052a7be <+372>:	mov    -0x28(%rbp),%rax
   0x000000000052a7c2 <+376>:	lea    0x40(%rax),%rdx
   0x000000000052a7c6 <+380>:	lea    -0x20(%rbp),%rax
   0x000000000052a7ca <+384>:	mov    %rax,%rsi
   0x000000000052a7cd <+387>:	mov    %rdx,%rdi
   0x000000000052a7d0 <+390>:	callq  0x52ab00 <std::list<blitz::mpu::TransportModule::BlitzTcpBuffer*, std::allocator<blitz::mpu::TransportModule::BlitzTcpBuffer*> >::push_back(blitz::mpu::TransportModule::BlitzTcpBuffer* const&)>
   0x000000000052a7d5 <+395>:	mov    -0x28(%rbp),%rax
   0x000000000052a7d9 <+399>:	mov    %rax,%rdi
   0x000000000052a7dc <+402>:	callq  0x529c16 <blitz::mpu::TransportModule::HandleMpsWrite()>
   0x000000000052a7e1 <+407>:	jmp    0x52a83b <blitz::mpu::TransportModule::SendPacket(ObjectPtr<blitz::mpu::TransportPacket>&)+497>
   0x000000000052a7e3 <+409>:	mov    -0x30(%rbp),%rdx
   0x000000000052a7e7 <+413>:	mov    -0x28(%rbp),%rax

```

```
(gdb) disassemble 'ObjectPtr<blitz::mpu::TransportPacket>::operator->()'
// 这个操作符实际上这是判断该地址传入进来的对象实例地址是否为空
Dump of assembler code for function ObjectPtr<blitz::mpu::TransportPacket>::operator->(): 
   0x00000000004f84a2 <+0>:	push   %rbp
   0x00000000004f84a3 <+1>:	mov    %rsp,%rbp
   0x00000000004f84a6 <+4>:	sub    $0x10,%rsp           // 保留变量空间 2*8
   0x00000000004f84aa <+8>:	mov    %rdi,-0x8(%rbp)      //  rdi传入的参数放到第一个 slot
   0x00000000004f84ae <+12>:	mov    -0x8(%rbp),%rax  //
   0x00000000004f84b2 <+16>:	mov    (%rax),%rax   // 取 该地址的值 
   0x00000000004f84b5 <+19>:	test   %rax,%rax  // zf = %rax ==0  判断是否为0
   0x00000000004f84b8 <+22>:	jne    0x4f84d3 <ObjectPtr<blitz::mpu::TransportPacket>::operator->()+49>  //  assert(buff!=null)  
   0x00000000004f84ba <+24>:	mov    $0x57e180,%ecx
   0x00000000004f84bf <+29>:	mov    $0xb1,%edx
   0x00000000004f84c4 <+34>:	mov    $0x57e058,%esi
   0x00000000004f84c9 <+39>:	mov    $0x57e087,%edi
   0x00000000004f84ce <+44>:	callq  0x4f68f0 <__assert_fail@plt>
   0x00000000004f84d3 <+49>:	mov    -0x8(%rbp),%rax  //   重做
   0x00000000004f84d7 <+53>:	mov    (%rax),%rax      
   0x00000000004f84da <+56>:	leaveq                   //恢复栈顶  mov %rbp,%rsp,  pop %rbp
   0x00000000004f84db <+57>:	retq                     //返回现场 pop %rip ，jump to %rip
End of assembler dump.

```

崩溃点处 代码显示
`*((uint16_t*)(buff->buff->data)) = htons(packet->len);`
先计算 buff->buff ，
`0x000000000052a717 <+205>:	mov    -0x20(%rbp),%rax  // buff --> %rax`

再计算  buff->buff->data
`=> 0x000000000052a723 <+217>:	mov    0x18(%rax),%rbx `
 0x18(%rax) 中 (%rax) 就是 buff->buff 地址，偏移 24 后就是 data的位置， 见下面的验证计算。
 
栈帧基址 0x1fff0005b0  ,    -0x20(%rbp) buff 所在的位置是 0x1fff0005b0  ，观测其地址内容
```
(gdb) x/4xg 0x1fff000590
0x1fff000590:	0x0000000006354ac0	0x0100000100000064
0x1fff0005a0:	0x000000000000000c	0x00000000004f6ec0

```

亦可通过命令  得到
```
(gdb) print buff
$2 = (blitz::mpu::TransportModule::BlitzTcpBuffer *) 0x6354ac0

(gdb) print &buff
$3 = (blitz::mpu::TransportModule::BlitzTcpBuffer **) 0x1fff000590
```

buff 对应的类的内存布局如下:

```
 struct BlitzTcpBuffer
            {
                BlitzTcpBuffer(int len):totalLen(0), startPos(0) {
                    buff = defaultBlitzBufferPool.get();
                }
                BlitzBuffer::Ptr buff; //等同 BlitzBuffer *  8byte
                int totalLen;  //4byte
                int startPos;  //4byte
            };
			
BlitzBuffer 的内存布局如下:
class BlitzBuffer : public PoolAbleObject<BlitzBuffer> {
 public:
     typedef ObjectPtr<BlitzBuffer> Ptr;
 public:
     //缓存数据总长度;
     uint32_t len;
     uint8_t *data;
 };

class PoolAbleObject
{
private:
    ObjectPool<ObjectType>* _pool;
    int _refCount;
}

大约是
8 byte 虚表地址 
8 byte _pool
4 byte _refCount;
4 byte len 
8 byte data;  <== 这里偏移 24 byte
```

查看该处地址的内容前后左右的内容，地址减少16后 打印出来
```
(gdb) x/6xg 0x6354ab0
0x6354ab0:	0xcc183280acc082a1	0x65687a112a012003
//这是该行地址，前8个字节是指针，后面两个4字节是 totalLen 和 startPos
0x6354ac0:	0x373436315f69616e	0x2912333436303531
0x6354ad0:	0x80acc082a1e2d108	0xecc082a1e2d11032

按四字节访问
(gdb) x/12xw 0x6354ab0
0x6354ab0:	0xacc082a1	0xcc183280	0x2a012003	0x65687a11
// 后面两个是 totallen和startPos
0x6354ac0:	0x5f69616e	0x37343631	0x36303531	0x29123334
0x6354ad0:	0xa1e2d108	0x80acc082	0xe2d11032	0xecc082a1

打印出具体的值，地址16进制 
(gdb) print buff->startPos 
$4 = 689058612
(gdb) print buff->buff
$5 = {_ptr = 0x373436315f69616e}
(gdb) print buff->totalLen 
$6 = 909129009
(gdb) print buff->startPos 
$7 = 689058612
```
###  推测 和 验证
目测该地址 应该是越界的并且 totalLen 和 startPos 的数值不太对。
```
(gdb) x/10xg 0x373436315f69616e
0x373436315f69616e:	Cannot access memory at address 0x373436315f69616e

```


### 源码分析

#### mpu服务端 





处的 BlitzTcpBuffer 生命周期 
1. 创建/重新利用，从 _idleTcpBuffer 中获取，或者 从默认池 defaultBlitzBufferPool 中获取。
transport.cc  line 353 in  TransportModule::SendPacket ,BlitzTcpBuffer*  buff = _idleTcpBuffer.front();   缓存池自带 BlitzBuffer
or line line 349 new BlitzTcpBuffer(MAX_TCP_BUFFER_SIZE);
new 的时候用的 BlitzTcpBuffer 从 defaultBlitzBufferPool 池中获取 BlitzBuffer 

2. 初始化数据， 主要是memcpy

3. 放到 _usingTcpBuffer 交给应用使用.
line 360 in TransportModule::SendPacket ,_usingTcpBuffer.push_back(buff);
交给  HandleMpsWrite 使用
line 197 in HandleMpsWrite ,BlitzTcpBuffer* p = _usingTcpBuffer.front(); 

4. 用完，就从 应用池移到空闲池 
 BlitzTcpBuffer* p = _usingTcpBuffer.front();
send...
line 218 in HandleMpsWrite ,  _idleTcpBuffer.push_front(p); 来源


无论如何 ，这个地址都是有效的，全文搜索了一下 关于memcpy的地方，除了protobuf 外，
只有一处，

```cpp

        int TransportModule::SendPacket(TransportPacket::Ptr& packet) {

            bool sendToMps = (packet->ip == _mpsIpHost) && (packet->port == _mpsPort);
            if (sendToMps)
            {
                //tcp nonblocking send
                BlitzTcpBuffer* buff = NULL;
                if (_idleTcpBuffer.size() == 0)
                {
                    buff = new BlitzTcpBuffer(MAX_TCP_BUFFER_SIZE);
                }
                else
                {
                    buff = _idleTcpBuffer.front();
                    _idleTcpBuffer.pop_front();
                }
                *((uint16_t*)(buff->buff->data)) = htons(packet->len);
				// 这一行可能会导致 缓冲区溢出
                memcpy(buff->buff->data+2, packet->buffer->data, packet->len);
                buff->startPos = 0;
                buff->totalLen = packet->len+2;
                _usingTcpBuffer.push_back(buff);
                return HandleMpsWrite();

            }
```
			
因此猜测此处内存拷贝会有 地址越界。	需要追加一处断言来确保拷贝的长度在允许的范围内。
在函数的第一行， 加一个断言，
assert(packet->len < MAX_PACKET_SIZE-2 )


至于 packet -> len  是否会出现过大情况，分析了程序读的过程后发现， 程序协议 是  每一个包 都是  长度（2byte）+ 包体(变长) 的方式传递。 包与包之间并无界定符，但出现异常状况时，一定会出现错包情况。

```cpp
       int TransportModule::HandleMpsRecv()
        {
            socklen_t socklen = 0;
            static const size_t headLen = 2;
            static size_t bodyLen = 0;
            static size_t headRemain = 2;
            static size_t bodyRemain = 0;
            int size = 0;
            static BlitzBuffer::Ptr buffer = defaultBlitzBufferPool.get();
            static int totalLen = 0;
            do{
                //循环接收"长度",如果这次没收完,下次进来继续收
                while(headRemain > 0) {
                    size = recv(_mpsSocket, buffer->data + totalLen, headRemain, 0);
                    if (size > 0) {
                        headRemain -= size;
                        totalLen += size;
                        if (headRemain == 0){
                            bodyLen = ntohs(*(uint16_t*)buffer->data);
                            bodyRemain = bodyLen;
                        }
                    }
                    else if(size == 0){
                        //disconnect
                        return -1;
                    }
                    else{
                        return 0;
                    }
                }

                //循环接收"数据",如果这次没收完,下次进来继续收
                while(bodyRemain > 0) {//receive body
//这一行会产生缓冲区溢出， buffer->data 一定会被超出。该代码 可能无法被 valgrind 检测到，因为是 系统调用。
                    size = recv(_mpsSocket, buffer->data + totalLen, bodyRemain, 0);
                    if (size > 0) {
                        bodyRemain -= size;
                        totalLen += size;
                    }
                    else if(size == 0){
                        //disconnect
                        return -1;
                    }
                    else{
                        return 0;
                    }
                }

                //到这里收到了整个包
                if (_sink != NULL) {
                    TransportPacket::Ptr packet = defaultTransportPool.get();
                    packet->len = ((uint16_t) bodyLen);
                    packet->ip = (_mpsIpHost);
                    packet->port = ((uint16_t) _mpsPort);
                    packet->buffer = (buffer);

                    //buffer len header 2 bytes;
                    packet->buffer->data+=2;
                    _sink->OnNetPacketReceived(packet);
                    packet->buffer->data-=2;
                    _sink->OnProcessed();
                }

                //重置状态,为下一个包做准备
                buffer = defaultBlitzBufferPool.get();
                headRemain = headLen;
                bodyLen = 0;
                bodyRemain = 0;
                totalLen = 0;

            }
            while(1);

            return 0;
        }
```

#### mps 发包端的程序 代码确认
```java
blitz\service\blitz-mps\src\main\java\ac\blitz\mps\mpu\TcpMessageServer.java line  line 72

    @Override
    protected void doStart() throws Exception {

        serverBootstrap.group(new NioEventLoopGroup()).channel(NioServerSocketChannel.class)
                .childHandler(new ChannelInitializer<SocketChannel>() {
                    @Override
                    protected void initChannel(SocketChannel socketChannel) throws Exception {
// 一个包最大为 65500
                        socketChannel.pipeline().addLast(new LengthFieldBasedFrameDecoder(65500,0,2,0,2));
                        socketChannel.pipeline().addLast(new ProtobufDecoder(MpuMessage.getDefaultInstance()));
//填充 包头长度
line 72                        socketChannel.pipeline().addLast(new LengthFieldPrepender(2,false));
                        socketChannel.pipeline().addLast(new ProtobufEncoder());
                        socketChannel.pipeline().addLast(new MessageConnection());
                    }
                });
        serverBootstrap.bind(ip,port).sync();
    }
	
	
netty-all-4.1.38.Final.jar!\io\netty\handler\codec\LengthFieldPrepender.class
	    protected void encode(ChannelHandlerContext ctx, ByteBuf msg, List<Object> out) throws Exception {
        int length = msg.readableBytes() + this.lengthAdjustment;
        if (this.lengthIncludesLengthFieldLength) {
            length += this.lengthFieldLength;
        }

        ObjectUtil.checkPositiveOrZero(length, "length");
        switch(this.lengthFieldLength) {
        case 1: ... 
            break;
        case 2:
            if (length >= 65536) {
                throw new IllegalArgumentException("length does not fit into a short integer: " + length);
            }
			//这一行拼包头长度
            out.add(ctx.alloc().buffer(2).order(this.byteOrder).writeShort((short)length));
            break;
        case 3:
            ...
            break;
        case 4:
           ...
            break;
        case 5:
        case 6:
        case 7:
        default:
            throw new Error("should not reach here");
        case 8:
            out.add(ctx.alloc().buffer(8).order(this.byteOrder).writeLong((long)length));
        }

        out.add(msg.retain());
    
```

#### 验证
如果是因为接受数据时缓冲区溢出，那么运气好的话，应该能找到的那个缓冲所在的容器，该容器里面应该残留着第一个超常的数据包内容。
观测到源码里面，对象池 ObjectPool 使用的是 容器类 std::stack 
对于 std::stack 的内存布局，通过查找源代码可以得知 
std::stack 继承于 std::deque 继承于 _Deque_base 继承于  _Deque_impl_data

[stl_deque 源码地址](https://gcc.gnu.org/onlinedocs/gcc-4.6.3/libstdc++/api/a01049_source.html01049_source.html "stl_deque 源码地址")

```cpp
内存布局:
struct _Deque_impl_data
      {
	_Map_pointer _M_map ;  //8byte  //指针的指针  map表实际是一个 指针的指针 数组。
	size_t _M_map_size;    //4byte
	iterator _M_start;     // 4*8 个 指针
	iterator _M_finish;
}

    struct _Deque_iterator
    {
	  _Elt_pointer _M_cur;    //8 byte
      _Elt_pointer _M_first;  //8 byte  *_M_node
      _Elt_pointer _M_last;   //8 byte  _M_first+一个buff能容纳的元素个数
      _Map_pointer _M_node;   //8 byte  指针的指针,迭代器所指向的节点
	}
	
	
一个 deque buff size 是 512
libstdc++-v3\include\bits\stl_deque.h line 92
#define _GLIBCXX_DEQUE_BUF_SIZE 512

创建和初始化过程
template<typename _Tp, typename _Alloc>
    void
    _Deque_base<_Tp, _Alloc>::
    _M_initialize_map(size_t __num_elements) // maybe 0
    {
	// 计算需要多少个节点，   一个deque buff 可以 创建多个元素，  一个node 等于一个buff，冗余出一个node。
      const size_t __num_nodes = (__num_elements / __deque_buf_size(sizeof(_Tp))
				  + 1);  //1

      // 用一个map来维护， 这个map 数量是节点数+2,且最少是8，
      this->_M_impl._M_map_size = std::max((size_t) _S_initial_map_size ,
					   size_t(__num_nodes + 2));
      this->_M_impl._M_map = _M_allocate_map(this->_M_impl._M_map_size);

      // For "small" maps (needing less than _M_map_size nodes), allocation
      // starts in the middle elements and grows outwards.  So nstart may be
      // the beginning of _M_map, but for small maps it may be as far in as
      // _M_map+3.
//尽可能在中间开始分配。
      _Map_pointer __nstart = (this->_M_impl._M_map
			       + (this->_M_impl._M_map_size - __num_nodes) / 2); // 7/2=3
      _Map_pointer __nfinish = __nstart + __num_nodes;

      __try  //创建要求的数量的节点
	{ _M_create_nodes(__nstart, __nfinish); }
      __catch(...)
	{
	  _M_deallocate_map(this->_M_impl._M_map, this->_M_impl._M_map_size);
	  this->_M_impl._M_map = _Map_pointer();
	  this->_M_impl._M_map_size = 0;
	  __throw_exception_again;
	}
       //设置第一个node为_M_start， 
	   //其中_M_node = __new_node;_M_first = *__new_node;	_M_last = _M_first + difference_type(_S_buffer_size());
	   // last 实际地址 = first + sizeof(tp) * _S_buffer_size()
      this->_M_impl._M_start._M_set_node(__nstart); //设置到第一个node，
      this->_M_impl._M_finish._M_set_node(__nfinish - 1); //设置到最后一个node，如果__num_elements为0，刚好也是第一个。
      this->_M_impl._M_start._M_cur = _M_impl._M_start._M_first;
      this->_M_impl._M_finish._M_cur = (this->_M_impl._M_finish._M_first
					+ __num_elements
					% __deque_buf_size(sizeof(_Tp)));
    }
	
	//创建节点
	  template<typename _Tp, typename _Alloc>
    void
    _Deque_base<_Tp, _Alloc>::
    _M_create_nodes(_Map_pointer __nstart, _Map_pointer __nfinish)
    {
      _Map_pointer __cur;
      __try
	{ //逐一创建节点
	  for (__cur = __nstart; __cur < __nfinish; ++__cur)
	    *__cur = this->_M_allocate_node();
	}
      __catch(...)
	{
	  _M_destroy_nodes(__nstart, __cur);
	  __throw_exception_again;
	}
	
	_Ptr
      _M_allocate_node()
      {
	typedef __gnu_cxx::__alloc_traits<_Tp_alloc_type> _Traits;
	//一次创建缓冲区数量的节点，也即以此申请一个缓冲区
	return _Traits::allocate(_M_impl, __deque_buf_size(sizeof(_Tp)));
      }

```

```cpp
        class TransportPacket : public PoolAbleObject<TransportPacket> {
        public:
            typedef ObjectPtr<TransportPacket> Ptr;
        public:
            uint16_t len;
            uint16_t port;
            uint32_t ip;
            BlitzBuffer::Ptr buffer;
        };
template <typename ObjectType>
class PoolAbleObject
{
private:
    ObjectPool<ObjectType>* _pool;
    int _refCount;
}

内存布局大约如下:
虚表指针  8byte
*pool    8byte  
refcount 4byte
len      2byte
port     2byte
ip       4byte
（xx)    4byte //内存对齐
buffer   8byte  
```
我们可以通过  packet -> buffer -> _pool 找到 BlitzBuffer的 池，也就是   defaultBlitzBufferPool 的地址。

先确定buffer的位置
```
(gdb) print packet
$9 = (blitz::mpu::TransportPacket::Ptr &) @0x1fff000660: {_ptr = 0x6353d70}
(gdb) print &packet
$10 = (blitz::mpu::TransportPacket::Ptr *) 0x1fff000660

(gdb) x/40xg 0x6353d70
0x6353d70:	0x000000000057e410	0x00000000007ca920  //虚表位置 | pool 位置
0x6353d80:	0x4e20000c00000001	0x000000007f000001  // refcountl+len+port | ip+ aligned-filled
0x6353d90:	0x00000000062e5270	0x0000000000000000  <== buffer的位置 这是我想要的
0x6353da0:	0x0000000000000000	0x0000000000000000
0x6353db0:	0x0000000000000000	0x0000000000000070

(gdb)  x/4xw 0x6353d80
0x6353d80:	0x00000001	0x4e20000c	0x7f000001	0x00000000  
//refcount 值 =1 | len && port（待会儿再拆） | ip= 127.0.0.1 | aligned-filled 全是0
(gdb) x/2xh 0x6353d84
0x6353d84:	0x000c	0x4e20 // len=13 | port=20000 符合配置

(gdb) x/10xg 0x00000000062e5270
0x62e5270:	0x000000000057f850	0x00000000007ca980  //虚表指针 |  池的位置   <==这是我想要的
0x62e5280:	0x00000bb800000001	0x00000000062e52d0
0x62e5290:	0x0000000000000000	0x0000000000000000
0x62e52a0:	0x0000000000000000	0x0000000000000060
0x62e52b0:	0x0000000000000c00	0x0000000000000000

0x00000000007ca980 是 std::stack的实例的地址，
(gdb) x/40xg 0x00000000007ca980
//map的地址 | map size = 8 + 补齐
0x7ca980 <_ZN5blitz3mpu22defaultBlitzBufferPoolE>:	0x00000000062ce9a0	0x0000000000000008 
//start 迭代器 _M_cur _M_first _M_last _M_node 
0x7ca990 <_ZN5blitz3mpu22defaultBlitzBufferPoolE+16>:	0x00000000062cea20	0x00000000062cea20
0x7ca9a0 <_ZN5blitz3mpu22defaultBlitzBufferPoolE+32>:	0x00000000062cec20	0x00000000062ce9b8
//finish 迭代器 _M_cur _M_first _M_last _M_node ,元素是指针类型，偏移为8，可以看出只有一个元素
0x7ca9b0 <_ZN5blitz3mpu22defaultBlitzBufferPoolE+48>:	0x00000000062cea28	0x00000000062cea20
0x7ca9c0 <_ZN5blitz3mpu22defaultBlitzBufferPoolE+64>:	0x00000000062cec20	0x00000000062ce9b8
0x7ca9d0:	0x0000000000000000	0x0000000000000000
0x7ca9e0 <_ZN5blitz3mpu22defaultBlitzPacketPoolE>:	0x00000000062cef20	0x0000000000000008
0x7ca9f0 <_ZN5blitz3mpu22defaultBlitzPacketPoolE+16>:	0x00000000062cefa0	0x00000000062cefa0
0x7caa00 <_ZN5blitz3mpu22defaultBlitzPacketPoolE+32>:	0x00000000062cf1a0	0x00000000062cef38
0x7caa10 <_ZN5blitz3mpu22defaultBlitzPacketPoolE+48>:	0x00000000062cefb8	0x00000000062cefa0
0x7caa20 <_ZN5blitz3mpu22defaultBlitzPacketPoolE+64>:	0x00000000062cf1a0	0x00000000062cef38
0x7caa30:	0x0000000000000000	0x0000000000000000
0x7caa40 <_ZN5blitz3mpu22defaultMediaPacketPoolE>:	0x00000000062cf4a0	0x0000000000000008
0x7caa50 <_ZN5blitz3mpu22defaultMediaPacketPoolE+16>:	0x00000000062cf520	0x00000000062cf520
0x7caa60 <_ZN5blitz3mpu22defaultMediaPacketPoolE+32>:	0x00000000062cf720	0x00000000062cf4b8
0x7caa70 <_ZN5blitz3mpu22defaultMediaPacketPoolE+48>:	0x00000000062cf528	0x00000000062cf520
0x7caa80 <_ZN5blitz3mpu22defaultMediaPacketPoolE+64>:	0x00000000062cf720	0x00000000062cf4b8

(gdb) x/8xg 0x00000000062ce9a0
0x62ce9a0:	0x0000000000000000	0x0000000000000000
0x62ce9b0:	0x0000000000000000	0x00000000062cea20
0x62ce9c0:	0x0000000000000000	0x0000000000000000
0x62ce9d0:	0x0000000000000000	0x0000000000000000
map的地址内容, nstart 地址在 map+3处 也即0x00000000062ce9b8。
_M_last - _M_first = 0x00000000062cec20 - 0x00000000062cea20 =0x200 = 512 
start 和 finish 指向同一个 buff，finish._M_cur -  start._M_cur =8 byte ，刚好是一个指针类型的长度。因此，元素只有一个。


查看这两个元素的内容
第一个元素:
(gdb) x/10xg 0x00000000062cea20
0x62cea20:	0x0000000006358570	0x00000000062e5270
再查看其所指向的指针
(gdb) x/4xg 0x0000000006358570
0x6358570:	0x000000000057f850	0x00000000007ca980 // 虚表|pool
0x6358580:	0x00000bb800000000	0x00000000063585d0 // refcount+len | data地址
(gdb) x/8xw 0x0000000006358570
0x6358570:	0x0057f850	0x00000000	0x007ca980	0x00000000
0x6358580:	0x00000000	0x00000bb8	0x063585d0	0x00000000 //refcount=0，len=3000

第二个元素:
(gdb) x/4xg 0x00000000062e5270
0x62e5270:	0x000000000057f850	0x00000000007ca980
0x62e5280:	0x00000bb800000001	0x00000000062e52d0
(gdb) x/8xw 0x00000000062e5270
0x62e5270:	0x0057f850	0x00000000	0x007ca980	0x00000000
0x62e5280:	0x00000001	0x00000bb8	0x062e52d0	0x00000000

这个说明，最后一个元素的refcount=1 是在用的，而这个位置就是 参数packet -> buffer 地址0x00000000062e5270。 参见上面。

再查看 packet的pool的实例
(gdb) x/10xg 0x00000000007ca920  
0x7ca920 <_ZN5blitz3mpu20defaultTransportPoolE>:	0x00000000062ce420	0x0000000000000008
0x7ca930 <_ZN5blitz3mpu20defaultTransportPoolE+16>:	0x00000000062ce4a0	0x00000000062ce4a0
0x7ca940 <_ZN5blitz3mpu20defaultTransportPoolE+32>:	0x00000000062ce6a0	0x00000000062ce438
0x7ca950 <_ZN5blitz3mpu20defaultTransportPoolE+48>:	0x00000000062ce4a0	0x00000000062ce4a0
0x7ca960 <_ZN5blitz3mpu20defaultTransportPoolE+64>:	0x00000000062ce6a0	0x00000000062ce438

查看pool的对象
(gdb) x/10xg 0x00000000062ce4a0
0x62ce4a0:	0x0000000006353d70	0x00000000062e5ed0
0x62ce4b0:	0x0000000000000000	0x0000000000000000


里面是有两个pool对象的，其中第一个是我们所知道的参数 packet 对象，看看另外一个 
(gdb) x/10xg 0x00000000062e5ed0
0x62e5ed0:	0x000000000057e410	0x00000000007ca920   //虚表指针|pool池
0x62e5ee0:	0x4e200d7800000001	0x000000007f000001   //refcount=1  len=3448 port =20000 |ip=127.0.0.1
0x62e5ef0:	0x0000000006353de0	0x0000000000000000   //buffer 地址 <== 溢出起始地址 划重点，很重要
0x62e5f00:	0x0000000000000000	0x0000000000000000
0x62e5f10:	0x0000000000000000	0x0000000000000070


(gdb) print /x 0x06353de0 + 0x0d78
$4 = 0x6354b58
出问题的buff指针的地址是 0x6354ac0 < 0x6354b58 ，因此被覆盖，
事实上，整个 buff的对象丢被覆盖掉了，而不仅仅是其中的 buff->buff。

至此，实锤。



```




### 最后结论:
mps发送tcp包的时候，每一个包最大长度是  65500， 而 mpu 接受该报文时， 缓冲区长度 最大 3000， 
因此在接受数据时，就产生一次缓冲区溢出， 这个现象不是经常发生，只有在包超过3000的时候会发生。
缓冲区溢出引发的后果是不确定的，本次coredump是
因为有一次包发了3448长度的字节，冲掉了缓冲区里的一个buff对象，导致 地址失效，
引发了 segment fault 而导致。 

```cpp
                while(bodyRemain > 0) {//receive body
//这一行会产生缓冲区溢出， buffer->data 一定会被超出。该代码 可能无法被 valgrind 检测到，因为是 系统调用。
                    size = recv(_mpsSocket, buffer->data + totalLen, bodyRemain, 0);
```

该次缓冲在系统调用内执行，应该无法被valgrind检测到， 

而后在调用memcpy的时候又将会产生一次 缓冲区溢出。(这个能被valgrind检测到，被手工抑制了)
`                memcpy(buff->buff->data+2, packet->buffer->data, packet->len); `

触发原因:
1. 其一可能是 超过 3000的报文请求。
2. 其二可能是 收包异常，tcp粘包+解析不严格所致。

如果验证了是这个原因。 需要做两处修正，：
1. 发送端限制包大小，同时在接收端也判断包大小，不能超过缓冲。
2. 协议上增加包起始结束符号 ，如 STX (0x02) 开始, ETX (0x03) 。 STX PKG_LEN PKG_BODY ETX;



出问题的报文内容见附件。
