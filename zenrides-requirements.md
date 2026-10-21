# ZenRides product requirements

ZenRides is a ride HUD for motorbikers who ride as a pack. Riders on one group code see each other on a map, hold pack order on long highway days and short loops, and signal fuel, chai breaks, hazards, pace, regroup, and emergencies without leaving the ride.

This document states what the product must do for those riders. It does not record how the app is built.

## Who it is for

- A motorcycle pack riding together, not solo navigation and not cyclists.
- The ride lead, who starts the code, plans the days, and can end or delete the ride.
- The other riders, who join that code, follow the plan, and stay visible to the pack.
- The screen is a phone. A rider must be able to use it in the browser and as an installed Android app while the bike is the point of the ride.

## Purpose

- Riders on a shared ride must be able to track one another over long distances and short distances.
- Each rider must see their own position and the rest of the pack on one map, with distance measured from themselves.
- The group must share one ride code. Generating or joining that code must put the rider on the same ride.
- The lead must be able to set the shape of a multi-day ride. The pack must see today’s next halt without opening the planner.
- A rider must be able to warn the pack, call a fuel stop, a chai stop, a slower pace, a regroup, or an SOS, from the map.

## Platforms

- The app is the Flutter ZenRides app.
- It must run in the browser. The browser map is the Google Maps map on the Ride HUD.
- In the browser, a rider must sign in before the ride opens.
- An installable Android package must exist. That package is the Flutter app, signed so a phone can install it directly. It is not published to the Play Store. On Android the rider opens the ride directly. Their name and id stay on the device.
- An iPhone cannot install the Android package. On an iPhone the rider uses the web app, or a future signed iOS build.
- Map tiles are not part of the riding-group store. The store holds the pack: who is on the code, where they are, the shared plan, and an SOS.

## Sign-in

Sign-in applies in the browser.

- The rider enters a phone number and receives an SMS code. A 10-digit number is treated as an Indian number.
- After the code is accepted, the rider sets the name the pack will see. That name is shown on every ride they join.
- The ride does not open until both the phone and the name are set.
- If ZenRides cannot reach its backend at startup, it must say so and ask the rider to check the connection and refresh.

## Ride HUD

The Ride HUD is the home screen. It shows the map, the rider, the pack, and the ride controls on one phone-width layout.

- The map shows a green YOU marker for this rider.
- Other riders appear as motorcycle icons.
- The rider can show or hide the other bikes. Hiding them leaves YOU on the map.
- Recenter centers the map on YOU and zooms to twice the ride overview.
- While turn-by-turn navigation is running, Recenter puts YOU back in the following view: closer, aligned to the road, with the next stretch ahead.
- Removing a rider removes that person from Pack and from the map, including their SOS pin. A rider cannot remove themselves.
- GPS can be requested from the map. When permission is granted, YOU follows the live fix. If the fix drops, the last position stays on the map. If permission is denied, the HUD says so.
- A pause control stops live tracking without ending the ride. Resume starts it again.
- Ending the ride takes the route offline, turns GPS off, and clears fuel pins and directions.
- The headline states the live situation: waiting for a GPS fix, location set, the kilometres of the chosen route, or that the ride has ended.
- While the ride is live, the headline reminds the pack to hold cruising speed and the stagger. It does not show a speed number.
- When a known road hazard is within 2 km, the HUD names it and the distance to it.

## Pack

Pack is the riding-group list. It does not show speed.

- The top of Pack shows the group code and an END control. END ends the ride. After the ride has ended, Pack shows that the ride has ended instead of END.
- The ride lead also sees Delete ride. Deleting removes the plan, the roads, and the code for the whole pack.
- Each rider row shows the distance from you: ahead of you or behind you.
- A rider more than half a kilometre behind you is flagged as dropping back.
- Each rider is marked online or offline. A rider who has not reported a fresh position is offline, and their last position stays listed until it is too old to keep.
- YOU is the reference for those distances. The row says so, and it shows that rider’s role on the code.

## Broadcasts

The HUD offers a horizontal strip of broadcasts. The strip scrolls so every action stays reachable:

- Fuel
- Chai / Break
- Hazard
- Slow Pace
- Regroup
- SOS

Broadcasts are unavailable after the ride has ended. A notice can be acknowledged.

- Fuel toggles real petrol pumps on the map. The first tap shows them. The second tap hides them.
- When a route is selected, the pumps that stay on the map lie on that path.
- After Start, the navigation banner shows the distance to the nearest petrol pump.
- Chai / Break tells the group that this rider is holding. The Today card names who has stopped for chai.
- Hazard tells the group to slow down and hold their line.
- Slow Pace tells the group to ease off and hold the stagger.
- Regroup tells the group to come together. The Toll Naka screen shows how many riders have arrived and points riders back to Regroup on the HUD.
- SOS alerts the group, shows the sender’s last spot, and offers Call. Call opens the phone dialer. The rider can dismiss the SOS card. The last spot is also marked on the map.

## Search and navigation

The map includes destination search and turn-by-turn guidance.

- A search field labeled “Where to?” accepts a place name and offers matching places.
- Choosing a place draws the roads from the rider’s current position and offers more than one route when the road network has alternatives.
- Each route choice shows travel time, distance, and a short summary of the road. When live traffic is available, the time reflects it.
- The rider can select one of those routes. The selected road is the one drawn for navigation, and petrol pumps for that ride lie on that path.
- Start begins turn-by-turn guidance on the selected route: the next turn and the distance to it, time left, distance left, and arrival time.
- The guidance cards stay compact so the map remains the main view.
- The rider can leave guidance and return to the route choices, and can clear the search.

## Planning

A ride can last more than one day. Planning captures the shape of the trip without the live-ride controls in the way. The ride lead plans the ride. A rider who has joined someone else’s code sees that plan and does not edit it.

- The lead can set the number of days, the dates, the start, and the finish, and a start time and end time for each day.
- Each day has its own halts. A later day can start where the previous day ended.
- Select on Map arms the map. The next tap on the road drops a halt. The lead can remove a halt before saving.
- While planning, the lead can show fuel pumps and toll nakas, and can add a toll naka as a halt.
- While the planning screen is open, live-ride controls are hidden, including broadcasts, the live headline, the Today card, and SOS.
- Save leaves planning and returns to the live ride. Cancel leaves planning without treating the day as finished.
- The Today card on the live HUD shows the next halt and the kilometres left to it, who has stopped for chai, and End the day.
- End the day summarizes the day: distance covered, time on the road, who was still with the group, and whether the day’s point was reached.
- If no halt has been saved, the Today card tells the lead to plan the day from Tours. Other riders are told that the ride lead plans this one.
- Tours is also where a rider generates a code, joins a code, leaves a ride, or, as lead, deletes the ride.

## Toll Naka

Toll Naka is the pack’s regroup point on the ride.

- The screen names the toll naka the pack is using and shows how many riders have arrived.
- It tells riders to send Regroup from the Ride HUD as the pack rolls in.

## Riding groups

Riders share a group by code. The code looks like `ZEN-` followed by four digits. The rider can generate a new code or join an existing one.

- Generating a code makes that rider the ride lead and attaches them to a new ride.
- Joining a code attaches that rider to the existing ride as a pack rider.
- While the ride is live and not paused, this rider’s position keeps updating. Other riders on the same code appear in Pack and on the map.
- Removing a rider removes that person from the shared ride as well as from Pack and the map.
- SOS for the group is stored on the ride so the other riders on that code can see the last spot.
- A rider is known by the name they set and by an id kept for that device or sign-in. There is no separate account screen.

## Out of scope

- A Play Store listing.
- A public website that anyone can open without this machine.
- An installable iPhone app.
- A speedometer, or speed on the Pack list.
- Planning by a rider who joined someone else’s code.
