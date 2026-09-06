#!/bin/bash

# Motion Detection Test Script
# Tests motion detection algorithm without recording

# Configuration
MOTION_THRESHOLD="10000"  # Pixels changed threshold
CHECK_INTERVAL="3"  # Seconds between checks
FRAME_WIDTH="320"
FRAME_HEIGHT="240"
FUZZ_PERCENT="15"  # Ignore small differences (percentage)

# Function to check for motion using pixel aggregation
check_motion() {
    # Capture a frame at low resolution for analysis
    rpicam-still \
        --width "$FRAME_WIDTH" \
        --height "$FRAME_HEIGHT" \
        --timeout 1000 \
        --output /tmp/current_frame.jpg \
        --nopreview \
        --quality 50 \
        2>/dev/null

    if [ -f /tmp/current_frame.jpg ]; then
        if [ -f /tmp/previous_frame.jpg ]; then
            # Use ImageMagick to compare frames
            DIFF=$(compare -metric AE -fuzz "$FUZZ_PERCENT%" /tmp/previous_frame.jpg /tmp/current_frame.jpg null: 2>&1)

            # Remove non-numeric characters
            DIFF_CLEAN=$(echo "$DIFF" | grep -o '[0-9]*' | head -1)

            if [ -z "$DIFF_CLEAN" ]; then
                DIFF_CLEAN=0
            fi

            # Move current to previous for next comparison
            mv /tmp/current_frame.jpg /tmp/previous_frame.jpg

            # Return the difference value and motion status
            if [ "$DIFF_CLEAN" -gt "$MOTION_THRESHOLD" ]; then
                echo "MOTION DETECTED (Diff: $DIFF_CLEAN pixels)"
                return 0
            else
                echo "No motion (Diff: $DIFF_CLEAN pixels, Threshold: $MOTION_THRESHOLD)"
                return 1
            fi
        else
            # First frame, save as previous
            mv /tmp/current_frame.jpg /tmp/previous_frame.jpg
            echo "First frame captured - initializing baseline"
            return 0
        fi
    else
        echo "ERROR: Failed to capture frame"
        return 1
    fi
}

# Main test loop
echo "Motion Detection Test Started"
echo "Threshold: $MOTION_THRESHOLD pixels"
echo "Frame size: ${FRAME_WIDTH}x${FRAME_HEIGHT}"
echo "Fuzz: $FUZZ_PERCENT%"
echo "Press Ctrl+C to stop"
echo "-----------------------------------"

# Initialize counter
COUNTER=0

while true; do
    COUNTER=$((COUNTER + 1))
    TIMESTAMP=$(date '+%H:%M:%S')

    echo -n "[$TIMESTAMP] Check #$COUNTER: "

    # Run motion detection
    check_motion

    # Check exit code (0 = motion, 1 = no motion)
    if [ $? -eq 0 ]; then
        echo ">>> MOTION EVENT <<<"
    fi

    sleep "$CHECK_INTERVAL"
done
