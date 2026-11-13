#include "robot.hpp"

void turn_right() {
    turn_left();
    turn_left();
    turn_left();
}

int main() {
    // Solve any maze: find the token and deliver it to the goal.
    bool carrying = false;
    while (!(carrying && at_goal())) {
        if (!carrying && object_here()) {
            pick_object();
            carrying = true;
        }
        if (right_is_clear()) {
            turn_right();
            move();
        } else if (front_is_clear()) {
            move();
        } else {
            turn_left();
        }
    }
    put_object();
    return 0;
}