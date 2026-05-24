#!/usr/bin/env python3
"""
UFW Log Analyzer
Analyzes kernel firewall logs from /var/log/ufw.log and provides summary statistics and insights.

  python3 ~/src/scripts/ufw_log_analyzer.py -f <(ssh seaside sudo cat /var/log/ufw.log)

"""

import re
from collections import Counter, defaultdict
from datetime import datetime
import argparse
import sys


class UFWLogAnalyzer:
    def __init__(self, log_file='/var/log/ufw.log'):
        self.log_file = log_file
        self.entries = []
        self.src_ips = Counter()
        self.dst_ports = Counter()
        self.protocols = Counter()
        self.src_ports = Counter()
        self.countries = defaultdict(int)
        self.port_scan_suspects = defaultdict(set)
        
    def parse_log_line(self, line):
        """Parse a single UFW log line and extract relevant fields."""
        # Pattern to match UFW log entries
        pattern = r'UFW (BLOCK|ALLOW)'
        if not re.search(pattern, line):
            return None
        
        entry = {'raw': line}
        
        # Extract timestamp
        timestamp_match = re.match(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+[+-]\d{2}:\d{2})', line)
        if timestamp_match:
            entry['timestamp'] = timestamp_match.group(1)
        
        # Extract action
        action_match = re.search(r'UFW (BLOCK|ALLOW)', line)
        if action_match:
            entry['action'] = action_match.group(1)
        
        # Extract interface
        in_match = re.search(r'IN=(\S+)', line)
        if in_match:
            entry['interface'] = in_match.group(1)
        
        # Extract source IP
        src_match = re.search(r'SRC=([\d.]+)', line)
        if src_match:
            entry['src_ip'] = src_match.group(1)
        
        # Extract destination IP
        dst_match = re.search(r'DST=([\d.]+)', line)
        if dst_match:
            entry['dst_ip'] = dst_match.group(1)
        
        # Extract protocol
        proto_match = re.search(r'PROTO=(\w+)', line)
        if proto_match:
            entry['protocol'] = proto_match.group(1)
        
        # Extract source port
        spt_match = re.search(r'SPT=(\d+)', line)
        if spt_match:
            entry['src_port'] = int(spt_match.group(1))
        
        # Extract destination port
        dpt_match = re.search(r'DPT=(\d+)', line)
        if dpt_match:
            entry['dst_port'] = int(dpt_match.group(1))
        
        # Extract TTL
        ttl_match = re.search(r'TTL=(\d+)', line)
        if ttl_match:
            entry['ttl'] = int(ttl_match.group(1))
        
        # Check for SYN flag (connection attempts)
        entry['syn'] = 'SYN' in line and 'ACK' not in line
        
        return entry
    
    def analyze(self):
        """Read and analyze the log file."""
        try:
            with open(self.log_file, 'r') as f:
                for line in f:
                    entry = self.parse_log_line(line)
                    if entry:
                        self.entries.append(entry)
                        
                        # Collect statistics
                        if 'src_ip' in entry:
                            self.src_ips[entry['src_ip']] += 1
                            
                        if 'dst_port' in entry:
                            self.dst_ports[entry['dst_port']] += 1
                            
                            # Track port scanning behavior
                            if 'src_ip' in entry:
                                self.port_scan_suspects[entry['src_ip']].add(entry['dst_port'])
                        
                        if 'protocol' in entry:
                            self.protocols[entry['protocol']] += 1
                        
                        if 'src_port' in entry:
                            self.src_ports[entry['src_port']] += 1
                            
        except FileNotFoundError:
            print(f"Error: Log file '{self.log_file}' not found.")
            sys.exit(1)
        except PermissionError:
            print(f"Error: Permission denied reading '{self.log_file}'. Try running with sudo.")
            sys.exit(1)
    
    def get_port_description(self, port):
        """Return common service names for well-known ports."""
        common_ports = {
            20: 'FTP Data',
            21: 'FTP Control',
            22: 'SSH',
            23: 'Telnet',
            25: 'SMTP',
            53: 'DNS',
            80: 'HTTP',
            110: 'POP3',
            143: 'IMAP',
            443: 'HTTPS',
            445: 'SMB',
            3306: 'MySQL',
            3389: 'RDP',
            5432: 'PostgreSQL',
            5900: 'VNC',
            6379: 'Redis',
            8080: 'HTTP Proxy',
            27017: 'MongoDB',
        }
        return common_ports.get(port, 'Unknown')
    
    def print_summary(self):
        """Print a summary of the analysis."""
        print("=" * 80)
        print("UFW FIREWALL LOG ANALYSIS SUMMARY")
        print("=" * 80)
        print(f"\nTotal blocked/allowed events: {len(self.entries)}")
        
        if not self.entries:
            print("\nNo UFW log entries found.")
            return
        
        # Action breakdown
        actions = Counter(entry.get('action', 'UNKNOWN') for entry in self.entries)
        print(f"\nAction Breakdown:")
        for action, count in actions.most_common():
            print(f"  {action}: {count}")
        
        # Protocol breakdown
        print(f"\nProtocol Distribution:")
        for proto, count in self.protocols.most_common():
            percentage = (count / len(self.entries)) * 100
            print(f"  {proto}: {count} ({percentage:.1f}%)")
        
        # Top source IPs
        print(f"\nTop 10 Source IPs (Most Active Attackers):")
        for ip, count in self.src_ips.most_common(10):
            percentage = (count / len(self.entries)) * 100
            print(f"  {ip}: {count} attempts ({percentage:.1f}%)")
        
        # Top targeted ports
        print(f"\nTop 10 Targeted Ports:")
        for port, count in self.dst_ports.most_common(10):
            service = self.get_port_description(port)
            percentage = (count / len(self.entries)) * 100
            print(f"  Port {port} ({service}): {count} attempts ({percentage:.1f}%)")
    
    def print_insights(self):
        """Print interesting insights from the analysis."""
        print("\n" + "=" * 80)
        print("SECURITY INSIGHTS")
        print("=" * 80)
        
        # Detect potential port scans
        print("\n🔍 Potential Port Scanning Activity:")
        port_scanners = [(ip, ports) for ip, ports in self.port_scan_suspects.items() 
                        if len(ports) >= 5]
        
        if port_scanners:
            port_scanners.sort(key=lambda x: len(x[1]), reverse=True)
            for ip, ports in port_scanners[:10]:
                print(f"  {ip}: Attempted {len(ports)} different ports (Total: {self.src_ips[ip]} attempts)")
                # Show sample of ports
                sample_ports = sorted(list(ports))[:10]
                print(f"    Sample ports: {', '.join(map(str, sample_ports))}")
        else:
            print("  No significant port scanning detected.")
        
        # Detect brute force attempts (multiple attempts to same service)
        print("\n🔨 Potential Brute Force Targets:")
        ssh_attempts = self.dst_ports.get(22, 0)
        rdp_attempts = self.dst_ports.get(3389, 0)
        ftp_attempts = self.dst_ports.get(21, 0)
        
        if ssh_attempts > 0:
            print(f"  SSH (Port 22): {ssh_attempts} connection attempts")
        if rdp_attempts > 0:
            print(f"  RDP (Port 3389): {rdp_attempts} connection attempts")
        if ftp_attempts > 0:
            print(f"  FTP (Port 21): {ftp_attempts} connection attempts")
        
        if ssh_attempts == 0 and rdp_attempts == 0 and ftp_attempts == 0:
            print("  No significant brute force attempts on common services.")
        
        # Unusual ports
        print("\n🎯 Unusual/High-Risk Port Targeting:")
        high_risk_ports = {
            23: 'Telnet (Unencrypted)',
            3306: 'MySQL (Database)',
            5432: 'PostgreSQL (Database)',
            6379: 'Redis (Database)',
            27017: 'MongoDB (Database)',
            5900: 'VNC (Remote Desktop)',
            445: 'SMB (File Sharing)',
        }
        
        found_unusual = False
        for port, description in high_risk_ports.items():
            count = self.dst_ports.get(port, 0)
            if count > 0:
                print(f"  Port {port} ({description}): {count} attempts")
                found_unusual = True
        
        if not found_unusual:
            print("  No attempts on high-risk services detected.")
        
        # SYN flood detection (many SYN packets)
        syn_count = sum(1 for entry in self.entries if entry.get('syn', False))
        if syn_count > 0:
            percentage = (syn_count / len(self.entries)) * 100
            print(f"\n⚠️  SYN Packets: {syn_count} ({percentage:.1f}%)")
            if percentage > 50:
                print(f"     High percentage of SYN packets may indicate SYN flood attempts")
        
        # Geographic diversity (based on IP patterns - simplified)
        print(f"\n🌍 Attack Source Diversity:")
        print(f"  Unique source IPs: {len(self.src_ips)}")
        
        # Identify persistent attackers
        persistent = [(ip, count) for ip, count in self.src_ips.items() if count >= 50]
        if persistent:
            print(f"\n🚨 Persistent Attackers (50+ attempts):")
            persistent.sort(key=lambda x: x[1], reverse=True)
            for ip, count in persistent[:5]:
                print(f"  {ip}: {count} attempts")
        
        # Recommendations
        print("\n" + "=" * 80)
        print("RECOMMENDATIONS")
        print("=" * 80)
        
        if port_scanners:
            print("\n• Consider implementing rate limiting or fail2ban for repeated offenders")
        
        if ssh_attempts > 100:
            print("• High SSH attack volume detected - ensure:")
            print("  - SSH key authentication is enabled")
            print("  - Password authentication is disabled")
            print("  - Consider changing SSH port or using port knocking")
        
        if persistent:
            print(f"\n• Consider blocking persistent attackers at network perimeter:")
            for ip, count in persistent[:3]:
                print(f"  - {ip}")
        
        print("\n• Keep monitoring logs regularly for new attack patterns")
        print("• Ensure all services exposed to internet are necessary and updated")


def main():
    parser = argparse.ArgumentParser(
        description='Analyze UFW firewall logs and provide security insights'
    )
    parser.add_argument(
        '-f', '--file',
        default='/var/log/ufw.log',
        help='Path to UFW log file (default: /var/log/ufw.log)'
    )
    
    args = parser.parse_args()
    
    analyzer = UFWLogAnalyzer(args.file)
    analyzer.analyze()
    analyzer.print_summary()
    analyzer.print_insights()
    
    print("\n" + "=" * 80)
    print()


if __name__ == '__main__':
    main()
