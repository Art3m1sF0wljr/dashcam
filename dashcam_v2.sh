#!/bin/bash

# Dashcam recording script with home detection and motion detection
# Records only when away from home AND motion detected (or recently detected)

# Configuration
OUTPUT_DIR="/home/pi/dashcam"
HOME_GATEWAY="192.168.8.1"
PING_TIMEOUT="1"
CHECK_INTERVAL="3"
MOTION_CHECK_INTERVAL="30"  # Check for motion every 30 seconds
RECORDING_EXTENSION="600"   # Keep recording for 10 minutes after last motion (600 seconds)
BITRATE="3000000"  # 3 Mbps
FPS="25"
MOTION_THRESHOLD="10000"  # Pixels changed threshold (adjust based on testing)

# Function to check if we're home
check_home() {
    if ping -c 1 -W "$PING_TIMEOUT" "$HOME_GATEWAY" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to check for motion using pixel aggregation
check_motion() {
    # Capture a frame at low resolution for analysis
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
            # Use ImageMagick to compare frames
            # -metric AE counts absolute error (number of different pixels)
            # -fuzz 15% ignores small differences (leaves, lighting changes)
            DIFF=$(compare -metric AE -fuzz 15% /tmp/previous_frame.jpg /tmp/current_frame.jpg null: 2>&1)

            # Remove non-numeric characters
            DIFF_CLEAN=$(echo "$DIFF" | grep -o '[0-9]*' | head -1)

            if [ -z "$DIFF_CLEAN" ]; then
                DIFF_CLEAN=0
            fi

            # Move current to previous for next comparison
            mv /tmp/current_frame.jpg /tmp/previous_frame.jpg

            # Return success if motion detected (DIFF > threshold)
            if [ "$DIFF_CLEAN" -gt "$MOTION_THRESHOLD" ]; then
                return 0  # Motion detected
            else
                return 1  # No motion
            fi
        else
            # First frame, save as previous
            mv /tmp/current_frame.jpg /tmp/previous_frame.jpg
            return 0  # Assume motion on first check
        fi
    fi

    return 1  # No motion (camera failed)
}

# Main loop
while true; do
    if check_home; then
        echo "$(date): Car is home, not recording"
        sleep "$CHECK_INTERVAL"

        # Clear previous frame when home
        rm -f /tmp/previous_frame.jpg
    else
        # We're away from home
        echo "$(date): Car is away, checking for motion"

        # Initialize motion detection
        if check_motion; then
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

            # Recording loop with motion re-check
            LAST_MOTION_TIME=$(date +%s)
            MOTION_CHECK_COUNTER=0

            while true; do
                # Check if rpicam-vid is still running
                if ! kill -0 "$RPICAM_PID" 2>/dev/null; then
                    echo "$(date): Recording process ended unexpectedly"
                    break
                fi

                # Check if we're home
                if check_home; then
                    echo "$(date): Arrived home, stopping recording"
                    kill -INT "$RPICAM_PID"
                    wait "$RPICAM_PID" 2>/dev/null
                    echo "$(date): Recording stopped"
                    break
                fi

                # Check for motion every MOTION_CHECK_INTERVAL seconds
                MOTION_CHECK_COUNTER=$((MOTION_CHECK_COUNTER + CHECK_INTERVAL))
                if [ "$MOTION_CHECK_COUNTER" -ge "$MOTION_CHECK_INTERVAL" ]; then
                    MOTION_CHECK_COUNTER=0

                    # Check for motion (this takes ~1 second)
                    if check_motion; then
                        LAST_MOTION_TIME=$(date +%s)
                        echo "$(date): Motion detected, extending recording"
                    fi
                fi

                # Stop recording if no motion for RECORDING_EXTENSION seconds
                CURRENT_TIME=$(date +%s)
                TIME_SINCE_MOTION=$((CURRENT_TIME - LAST_MOTION_TIME))

                if [ "$TIME_SINCE_MOTION" -ge "$RECORDING_EXTENSION" ]; then
                    echo "$(date): No motion for 10 minutes, stopping recording"
                    kill -INT "$RPICAM_PID"
                    wait "$RPICAM_PID" 2>/dev/null
                    echo "$(date): Recording stopped after motion timeout"
                    break
                fi

                sleep "$CHECK_INTERVAL"
            done
        else
            echo "$(date): No motion detected, waiting"
            sleep "$CHECK_INTERVAL"
        fi
    fi
done
