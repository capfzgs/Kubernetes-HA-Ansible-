cat > /usr/local/bin/k8s-dnat-setup.sh << "SCRIPT"
#!/bin/bash
if ! iptables -t nat -C OUTPUT -d 192.168.88.200 -p tcp --dport 6443 \
  -j DNAT --to-destination 192.168.88.119:6443 2>/dev/null; then
  iptables -t nat -I OUTPUT 1 -d 192.168.88.200 -p tcp --dport 6443 \
    -j DNAT --to-destination 192.168.88.119:6443
  echo "$(date): DNAT added" >> /var/log/k8s-dnat.log
fi
