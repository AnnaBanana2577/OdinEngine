// Package net replicates game state between a server and clients. See docs/netcode.md.
package net

MAX_PLAYERS :: #config(NET_MAX_PLAYERS, 32)

Tick      :: distinct u32
Player_Id :: distinct u8

NO_PLAYER :: Player_Id(255)

#assert(MAX_PLAYERS > 0 && MAX_PLAYERS < int(NO_PLAYER))
