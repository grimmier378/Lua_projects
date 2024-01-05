This repo is going to house all of my LUA projects. 
SMC is the first one.

 Reworking SoloLootManager to be a Spawn Checker thank you Jackalo.

 Basically LUA version of MQ2SpawnMaster using Sql Lite. eventually!
 
Goals for this project. 
  * have the lua scan the zone for all mobs, populate them into a table on the gui 
  * allow the user to search for npcs by name and navigate to them 
  * allow the user to flag an NPC for tracking, this will move them to the other tab. 
  * I would like to have the flags for tracking stay saved in a database by that can be filtered by zone (since some npc's can be in multiple zones.)
  * If an npc is flagged for tracking, and it isn't up, the entry shouldnt appear inthe tracking tab. 
  * if the npc spawns while in the zone it should appear in the tracking tab, and notifications can be configured 
  * any changes to flagging should be saved to the database. and only spawns flagged either track or ignore should be written, we don't want a HUGE list of "a snake"'s appearing
  * setting a spawn to ingnore should keep it in the database but not activly search for it
  * on load or changing zone we should query the database for the npcs in the current zone and then refresh the zone for spawns in the zone to compare to.

Current Status
 
 Working
   * Pooling the zone for spawns and displaying them works. 
   * toggling the track and ignore radio buttons does move the entry onto and off of the tracking tab
   * NavTo button is functioning. this works great especially with being able to search for names and click nav.
   * Searching the sone tab works 
 Not Working
   * writing and reading from the database  currently you lose all data when the script is reloaded. 
   * doesn't automatically refresh the zone on zoning, it does change the name on tab to current zone. but the data is stale and you need to press refresh button
 Future 
   * all of the other items not listed in working and not working.

