#!/bin/bash
# scripts/stop.sh
# Kills all echo-system processes cleanly on Windows (Git Bash) or Linux/Mac.

echo "🛑 Stopping Echo-System..."

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
  taskkill /F /IM orchestrator.exe 2>/dev/null && echo "   Stopped orchestrator" || echo "   Orchestrator not running"
  taskkill /F /IM node-agent.exe   2>/dev/null && echo "   Stopped node agents"  || echo "   Node agents not running"
else
  pkill -f "bin/orchestrator" 2>/dev/null && echo "   Stopped orchestrator" || echo "   Orchestrator not running"
  pkill -f "bin/node-agent"   2>/dev/null && echo "   Stopped node agents"  || echo "   Node agents not running"
fi

read -p "   Stop Ollama instances too? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    taskkill /F /IM ollama.exe 2>/dev/null && echo "   Stopped Ollama" || echo "   Ollama not running"
  else
    pkill -f "ollama serve" 2>/dev/null && echo "   Stopped Ollama" || echo "   Ollama not running"
  fi
fi

echo "✅  Done"
