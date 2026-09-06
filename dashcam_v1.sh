#!/bin/bash

# Dashcam recording script with home detection and continuous monitoring
# Records 720p video from Pi Camera v1 (OV5647) only when away from home
# Checks for home by pinging the gateway/router

# Configuration
OUTPUT_DIR="/home/pi/dashcam"
RESOLUTION="1280x720"
FPS="30"
BITRATE="4000000"  # 8 Mbps for 720p
HOME_GATEWAY="192.168.8.1"  # Gateway/router IP
PING_TIMEOUT="1"  # 1 second timeout
CHECK_INTERVAL="30"  # Check every 3 seconds

# Function to check if we're home by pinging the gateway
check_home() {
    # Ping the gateway - it's always on and responds fast
    if ping -c 1 -W "$PING_TIMEOUT" "$HOME_GATEWAY" > /dev/null 2>&1; then
        return 0  # Home (gateway reachable)
    else
        return 1  # Away (gateway not reachable)
    fi
}

# Main loop
while true; do
    if check_home; then
        echo "$(date): Car is home, not recording"
        sleep "$CHECK_INTERVAL"
    else
        echo "$(date): Car is away, starting recording"

        # Create output directory if it doesn't exist
        mkdir -p "$OUTPUT_DIR"

        # Generate filename with timestamp
        FILENAME="$OUTPUT_DIR/rec_$(date +%Y%m%d_%H%M%S).h264"

        # Start rpicam-vid in the background
        rpicam-vid \
            --width 1280 \
            --height 720 \
            --framerate "$FPS" \
            --bitrate "$BITRATE" \
            --timeout 0 \
            --output "$FILENAME" \
            --nopreview \
            --awb auto \
            --exposure normal \
            --flush &

        # Store the PID of rpicam-vid
        RPICAM_PID=$!

        echo "$(date): Recording started, PID: $RPICAM_PID"

        # Monitor loop - check every ~3 seconds if we're home
        while true; do
            # Check if rpicam-vid is still running
            if ! kill -0 "$RPICAM_PID" 2>/dev/null; then
                echo "$(date): Recording process ended unexpectedly"
                break
            fi

            # Check if we're home now
            if check_home; then
                echo "$(date): Arrived home, stopping recording"

                # Try graceful stop with SIGINT first
                kill -INT "$RPICAM_PID" 2>/dev/null

                # Wait up to 5 seconds for graceful shutdown
                for i in {1..5}; do
                    if ! kill -0 "$RPICAM_PID" 2>/dev/null; then
                        break
                    fi
                    sleep 1
                done

                # If still running, force kill with SIGTERM
                if kill -0 "$RPICAM_PID" 2>/dev/null; then
                    echo "$(date): Graceful stop failed, forcing termination"
                    kill -TERM "$RPICAM_PID" 2>/dev/null
                    sleep 1
                fi

                # Last resort: SIGKILL
                if kill -0 "$RPICAM_PID" 2>/dev/null; then
                    echo "$(date): Force killing recording process"
                    kill -KILL "$RPICAM_PID" 2>/dev/null
                    sleep 1
                fi

                # Wait for the process to fully terminate
                wait "$RPICAM_PID" 2>/dev/null

                echo "$(date): Recording stopped, file saved: $FILENAME"
                break
            fi

            # Sleep for the check interval
            sleep "$CHECK_INTERVAL"
        done
    fi
done
