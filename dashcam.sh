#!/bin/bash

# Dashcam recording script with home detection and motion detection
# Records only when away from home AND motion detected (or recently detected)
# HOME CHECK OVERRIDES EVERYTHING

# Configuration
OUTPUT_DIR="/home/pi/dashcam"
HOME_GATEWAY="192.168.8.1"
PING_TIMEOUT="1"
CHECK_INTERVAL="3"
MOTION_CHECK_INTERVAL="30"  # Check for motion every 30 seconds
RECORDING_EXTENSION="600"   # Keep recording for 10 minutes after last motion
BITRATE="3000000"
FPS="25"
MOTION_THRESHOLD="10000"

# Function to check if we're home (HIGHEST PRIORITY)
check_home() {
    if ping -c 1 -W "$PING_TIMEOUT" "$HOME_GATEWAY" > /dev/null 2>&1; then
        return 0  # Home
    else
        return 1  # Away
    fi
}

# Function to check for motion using pixel aggregation
check_motion() {
    rpicam-still \
        --width 320 \
        --height 240 \
        --timeout 1000 \
        --output /tmp/current_frame.jpg \
        --nopreview \
        --quality 50 \
        2>/dev/null

    if [ -f /tmp/current_frame.jpg ]; then
        if [ -f /tmp/previous_frame.jpg ]; then
            DIFF=$(compare -metric AE -fuzz 15% /tmp/previous_frame.jpg /tmp/current_frame.jpg null: 2>&1)
            DIFF_CLEAN=$(echo "$DIFF" | grep -o '[0-9]*' | head -1)

            if [ -z "$DIFF_CLEAN" ]; then
                DIFF_CLEAN=0
            fi

            mv /tmp/current_frame.jpg /tmp/previous_frame.jpg

            if [ "$DIFF_CLEAN" -gt "$MOTION_THRESHOLD" ]; then
                return 0  # Motion detected
            else
                return 1  # No motion
            fi
        else
            mv /tmp/current_frame.jpg /tmp/previous_frame.jpg
            return 0  # Assume motion on first check
        fi
    fi

    return 1
}

# Function to stop recording safely
stop_recording() {
    local PID=$1
    local REASON=$2

    echo "$(date): Stopping recording - $REASON"

    # Try graceful stop with SIGINT
    kill -INT "$PID" 2>/dev/null

    # Wait up to 5 seconds
    for i in {1..5}; do
        if ! kill -0 "$PID" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # Force kill if still running
    if kill -0 "$PID" 2>/dev/null; then
        echo "$(date): Force stopping recording"
        kill -TERM "$PID" 2>/dev/null
        sleep 1
    fi

    # Last resort
    if kill -0 "$PID" 2>/dev/null; then
        kill -KILL "$PID" 2>/dev/null
        sleep 1
    fi

    wait "$PID" 2>/dev/null
    echo "$(date): Recording stopped"
}

# Main loop
while true; do
    # ALWAYS CHECK HOME FIRST
    if check_home; then
        echo "$(date): Car is home, not recording"
        rm -f /tmp/previous_frame.jpg  # Clear motion reference
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # We're away from home
    echo "$(date): Car is away, checking for motion"

    # Check for motion
    if ! check_motion; then
        echo "$(date): No motion detected, waiting"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # Motion detected, start recording
    echo "$(date): Motion detected, starting recording"
    mkdir -p "$OUTPUT_DIR"
    FILENAME="$OUTPUT_DIR/rec_$(date +%Y%m%d_%H%M%S).h264"

    # Start recording
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

    RPICAM_PID=$!
    echo "$(date): Recording started, PID: $RPICAM_PID"

    # Recording loop
    LAST_MOTION_TIME=$(date +%s)
    MOTION_CHECK_COUNTER=0

    while true; do
        # PRIORITY 1: Check if home (override everything)
        if check_home; then
            stop_recording "$RPICAM_PID" "Arrived home"
            break
        fi

        # PRIORITY 2: Check if recording process died
        if ! kill -0 "$RPICAM_PID" 2>/dev/null; then
            echo "$(date): Recording process ended unexpectedly"
            break
        fi

        # PRIORITY 3: Check for motion periodically
        MOTION_CHECK_COUNTER=$((MOTION_CHECK_COUNTER + CHECK_INTERVAL))
        if [ "$MOTION_CHECK_COUNTER" -ge "$MOTION_CHECK_INTERVAL" ]; then
            MOTION_CHECK_COUNTER=0

            if check_motion; then
                LAST_MOTION_TIME=$(date +%s)
                echo "$(date): Motion detected, extending recording"
            fi
        fi

        # PRIORITY 4: Check if motion timeout expired
        CURRENT_TIME=$(date +%s)
        TIME_SINCE_MOTION=$((CURRENT_TIME - LAST_MOTION_TIME))

        if [ "$TIME_SINCE_MOTION" -ge "$RECORDING_EXTENSION" ]; then
            stop_recording "$RPICAM_PID" "No motion for 10 minutes"
            break
        fi

        sleep "$CHECK_INTERVAL"
    done
done
