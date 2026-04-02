# ZTE中兴 问天7200 Pro+ 下跑的openfortivpn，支持局域网设备直接访问vpn网段，支持自动重连

## https://github.com/st0pli/docker-openfortivpn

## latest From alpine:latest
### docker pull st0p/openfortivpn:latest

## openfortivpn配置文件 /etc/openfortivpn/config
``` ini
host = vpn-gateway
port = 8443
username = foo
set-dns = 0
pppd-use-peerdns = 0
trusted-cert = e46d4aff08ba6914e64daa85bc6112a422fa7ce16631bff0b592a28556f993db
pppd-ifname = openfortivpn
```

## 环境变量配置参数

### VPN 基本配置
| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `VPN_CONFIG_PATH` | `/etc/openfortivpn/config` | VPN 配置文件路径 |
| `VPN_LOG_PATH` | `/var/log/openfortivpn` | VPN 日志目录路径 |
| `VPN_INTERFACE` | `openfortivpn` | VPN 虚拟接口名称 |
| `LAN_INTERFACE` | `br0` | 局域网接口名称（用于 FORWARD 规则） |

### 超时配置
| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `MAX_WAIT_INTERFACE` | `30` | 等待 VPN 接口出现的最长时间（秒） |
| `MAX_WAIT_IP` | `60` | 等待获取 IP 地址的最长时间（秒） |
| `RECHECK_INTERVAL` | `2` | 检查间隔时间（秒） |
| `PROCESS_CHECK_INTERVAL` | `10` | 进程健康检查间隔（秒） |
| `RESTART_DELAY` | `5` | 重启前等待时间（秒） |
| `STARTUP_FAIL_DELAY` | `10` | 启动失败后重试等待时间（秒） |

---

## 使用示例
``` bash
# 基础使用
docker run -d \
  --name openfortivpn \
  --cap-add NET_ADMIN \
  --device /dev/ppp \
  --network host \
  --restart=always \
  -v $(pwd)/config:/etc/openfortivpn/config:ro \
  -v $(pwd)/logs:/var/log/openfortivpn \
  -e VPN_INTERFACE=openfortivpn \
  -e LAN_INTERFACE=br0 \
  st0p/openfortivpn:latest
```
