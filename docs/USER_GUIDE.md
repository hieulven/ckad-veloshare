# VeloShare Rider Guide

VeloShare is a city bike-share service — unlock a bike, ride, return it, and get charged automatically for the time you rode.

## Table of contents

- [Getting started](#getting-started)
- [Logging in](#logging-in)
- [My profile and tier](#my-profile-and-tier)
- [Finding a station](#finding-a-station)
- [Taking a ride](#taking-a-ride)
- [Understanding your fare](#understanding-your-fare)
- [My trips](#my-trips)
- [Frequently asked questions](#frequently-asked-questions)

## Getting started

Open the VeloShare dashboard in your browser:

```
http://localhost/
```

> This is a local demo environment, so it runs over plain HTTP (no `https://`) and there is nothing to install.

## Logging in

You'll land on a login page. Enter the email and password your VeloShare admin gave you.

- If your email or password is wrong, you'll see an error and stay on the login page.
- If you're a rider who was added to the system a while ago and never got a password, you won't be able to log in yet — ask your admin to set one for you.
- Once you're in, stay logged in for up to **1 hour**. After that, the dashboard will automatically send you back to the login page — just sign in again.

## My profile and tier

The **My Profile** page shows your name, email, and membership tier. Your tier decides how much you pay per minute:

| Tier | Cost per minute |
|---|---|
| Standard | 15c |
| Member | 8c |
| Day Pass | 5c |

Every ride also has a flat **$1.00 unlock fee**, on top of the per-minute cost. See [Understanding your fare](#understanding-your-fare) below for how this adds up.

If you want to change your tier, ask your admin — riders can't change their own tier from the dashboard.

## Finding a station

The **Stations** page lists every VeloShare station, along with:

- How many docks it has in total (capacity)
- How many docks are currently free (docks available)

Use this to find a nearby station with an open dock before you head out, and to check a destination station has room for your bike when you return it.

## Taking a ride

1. Go to **My Ride**.
2. Pick the station where you're unlocking a bike and select **Start Ride**.
3. Ride!
4. When you're done, pick the station where you're returning the bike and select **End Ride**.
5. Your fare is calculated automatically and shown on screen (for example, `$1.08`).

**You can only have one active ride at a time.** If you try to start a second ride while one is already in progress, VeloShare will stop you with an "already has an active trip" message — end your current ride first.

## Understanding your fare

Your fare is:

```
fare = $1.00 unlock fee + (minutes ridden × your tier's per-minute rate × surge)
```

Surge is a multiplier that can be higher than 1 at busy times (surge is set by VeloShare, not something you choose).

**Example:** A 10-minute ride on the Member tier (8c/min) at 1.5x surge:

```
100 (unlock) + 10 minutes × 8c × 1.5 = 100 + 120 = 220 cents = $2.20
```

## My trips

The **My Trips** page lists every ride you've taken, newest first, showing:

- Tier used for that ride
- Start and end time
- Fare charged
- Status (in progress or completed)

You will only ever see your own trips here — nobody else's rides show up on your account, and you can't view or end another rider's trip.

## Frequently asked questions

**I forgot my password / can't log in.**
Contact your VeloShare admin — they manage rider accounts and passwords.

**I got logged out after an hour.**
That's expected. Just log in again; your ride history is unaffected.

**Can I have two rides going at once?**
No. End your current ride before starting a new one.

**Why is my fare different from a friend's for the same ride length?**
Fares depend on your tier and on surge at the time of the ride, so two riders on different tiers (or riding at different times) will usually pay different amounts for the same number of minutes.
