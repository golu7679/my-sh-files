#!/bin/bash

# Port Management Script for macOS
# Usage: ./port_manager.sh PORT_NUMBER

# Check if port number is provided
if [ -z "$1" ]; then
    echo "❌ Error: Port number is required!"
    echo ""
    echo "Usage: $0 PORT_NUMBER"
    echo ""
    echo "Example:"
    echo "  $0 8080"
    echo "  $0 3000"
    echo "  $0 5432"
    exit 1
fi

PORT=$1

echo "==================================="
echo "Port Manager for macOS"
echo "==================================="
echo ""

# Function to check if port is in use
check_port() {
    echo "Checking port $PORT..."
    echo ""
    
    # Check if port is in use using lsof
    if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1 ; then
        echo "❌ Port $PORT is currently IN USE"
        echo ""
        echo "Process details:"
        lsof -i :$PORT
        echo ""
        
        # Get PID
        PID=$(lsof -ti :$PORT)
        echo "Process ID (PID): $PID"
        echo ""
        
        read -p "Do you want to kill this process? (y/n): " choice
        case "$choice" in 
            y|Y ) 
                kill -9 $PID
                echo "✅ Process killed. Port $PORT is now free."
                ;;
            n|N ) 
                echo "Process left running."
                ;;
            * ) 
                echo "Invalid choice. Process left running."
                ;;
        esac
    else
        echo "✅ Port $PORT is AVAILABLE"
    fi
}

# Function to find what's using a port
find_process() {
    echo "Finding process on port $PORT..."
    lsof -i :$PORT
}

# Function to kill process on port
kill_port() {
    PID=$(lsof -ti :$PORT)
    if [ -z "$PID" ]; then
        echo "No process found on port $PORT"
    else
        kill -9 $PID
        echo "✅ Killed process on port $PORT"
    fi
}

# Main execution
check_port

echo ""
echo "==================================="
echo "Other useful commands:"
echo "  Check port: lsof -i :$PORT"
echo "  Kill port: kill -9 \$(lsof -ti :$PORT)"
echo "  See all listening ports: lsof -iTCP -sTCP:LISTEN -n -P"
echo "==================================="
