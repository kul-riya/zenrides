# ZenRides requirements

ZenRides is a ride HUD for cyclists who travel together. Riders on one group code must be able to see each other on a map, stay in pack order over long highway days and short loops, and signal fuel, breaks, hazards, and emergencies without leaving the ride.

This document states what the product must do. It does not record how the app was built.

## Purpose

- Cyclists on a shared ride must be able to track one another for both long distances and short distances.
- Each rider must see their own position and the rest of the pack on one map, with distance measured from themselves.
- The group must share one ride code. Generating or joining that code must attach the rider to the same ride.
- The ride must keep working as a phone-sized screen in the browser and as an installed Android app.

## Platforms

- The app must be the Flutter ZenRides app.
- It must run in the browser. The browser map must be the Google Maps JavaScript map already used by the Ride HUD.
- An installable Android package must exist. That package is the Flutter app, signed so a phone can install it directly. It must not be published to the Play Store.
- An iPhone cannot install the Android package. On an iPhone the rider must use the web app, or a future signed iOS build.
- Map tiles must not come from Firebase. Firebase is only the riding-group store described below.

## Ride HUD

The Ride HUD is the home screen. It must show the map, the rider, the pack, and the ride controls on one phone-width layout.

- The map must show a green YOU marker for the rider.
- Other riders must appear as motorcycle icons.
- The rider must be able to show or hide the other bikes. Hiding them must leave YOU on the map.
- Recenter must center the map on YOU and zoom to 200% of the ride overview.
- While turn-by-turn navigation is running, Recenter must put YOU back in the following view: closer, aligned to the road, with the next stretch ahead.
- Removing a rider must remove that person from Pack and from the map. The rider must not be able to remove themselves.
- GPS must be requestable from the map. When permission is granted, YOU must follow the live fix. If the fix drops, the last position must stay on the map. If permission is denied, the HUD must say so.
- A pause control must stop live tracking without ending the ride. Resume must start it again.
- Ending the ride must take the route offline, turn GPS off, and clear fuel pins and directions.

## Pack

Pack is the riding-group list. It must not show speed.

- The top of Pack must show the group code and an END control. END ends the ride. After the ride has ended, Pack must show that the ride has ended instead of END.
- Each rider row must show the distance from you: ahead of you or behind you.
- A rider more than half a kilometre behind you must be flagged as dropping back.
- Each rider must be marked online or offline. A rider who has not reported a fresh position is offline, and their last position must still be listed until it is too old to keep.
- YOU is the reference for those distances. The row must say so.

## Broadcasts

The HUD must offer a horizontal strip of broadcasts. The strip must scroll so every action stays reachable:

- Fuel
- Chai / Break
- Hazard
- Slow Pace
- Regroup
- SOS

Broadcasts must be unavailable after the ride has ended. A notice must be acknowledgeable.

- Fuel must toggle real petrol pumps on the map. The first tap must show them. The second tap must hide them.
- When a route is selected, the pumps that stay on the map must lie on that path.
- After Start, the navigation banner must show the distance to the nearest petrol pump.
- Chai / Break must tell the group that this rider is holding. The Today card must name who has stopped for chai.
- Hazard must warn the group to slow down and hold their line.
- Slow Pace must tell the group to ease off and hold the stagger.
- Regroup must tell the group to come together. The Toll Naka screen must show how many riders have arrived and must point riders back to Regroup on the HUD.
- SOS must alert the group, show the sender’s last spot, and offer Call. Call must open the phone dialer. The rider must be able to dismiss the SOS card. The last spot must also be marked on the map.

## Search and navigation

The map must include destination search and turn-by-turn guidance.

- A search field labeled “Where to?” must accept a place name and offer matching places.
- Choosing a place must draw the roads from the rider’s current position and offer more than one route when the road network has alternatives.
- Each route choice must show travel time, distance, and a short summary of the road.
- The rider must be able to select one of those routes. The selected road must be the one drawn for navigation, and petrol pumps for that ride must lie on that path.
- Start must begin turn-by-turn guidance on the selected route: the next turn and the distance to it, time left, distance left, and arrival time.
- The guidance cards must stay compact so the map remains the main view.
- The rider must be able to leave guidance and return to the route choices, and must be able to clear the search.

## Planning

A ride can last more than one day. Planning must capture the shape of the trip without the live-ride controls in the way.

- The rider must be able to set the number of days, the start, and the finish.
- Each day must have its own halts.
- Select on Map must arm the map. The next tap on the road must drop a halt. The rider must be able to remove a halt before saving.
- While the planning screen is open, live-ride controls must be hidden, including broadcasts, the live headline, the Today card, and SOS.
- Save must leave planning and return to the live ride. Cancel must leave planning without treating the day as finished.
- The Today card on the live HUD must show the next halt and the kilometres left to it, who has stopped for chai, and End the day.
- End the day must summarize the day: distance covered, time on the road, who was still with the group, and whether the day’s point was reached.
- If no halt has been saved, the Today card must say to plan the day from Tours.

## Riding groups

Riders share a group by code. The code must look like `ZEN-` followed by four digits. The rider must be able to generate a new code or join an existing one.

- Generating a code or joining a code must write that rider to Cloud Firestore, project `myzenrides`, at `rides/{code}/riders`.
- Each rider document must carry the rider’s name, latitude, longitude, and the time of the update.
- While the ride is live and not paused, the rider’s position must keep updating on that path. Other riders on the same code must appear in Pack and on the map.
- Removing a rider must delete that rider from `rides/{code}/riders` as well as from Pack and the map.
- SOS for the group must be stored on the ride so the other riders on that code can see the last spot.
- Firebase Authentication is not set up. A rider is identified by a name and an id kept on the device, not by a signed-in account.
- Map tiles are not Firebase.

## Out of scope

The following are out of scope for now:

- A Play Store listing.
- A public website that anyone can open without this machine.
- An installable iPhone app.
