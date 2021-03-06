/*
    Copyright (c) 2016, Salesforce.org
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Salesforce.org nor the names of
      its contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/
/**
* @author Salesforce.org
* @date 2016
* @group Levels
* @description Batch class processes all Levels against Target objects, and updates any changes.
*/
public without sharing class LVL_LevelAssign_BATCH implements Database.Batchable<sObject>, Database.Stateful {
    /** @description Custom Settings record that defines Levels settings */
    @TestVisible
    private static Levels_Settings__c levelsSettings = UTIL_CustomSettingsFacade.getLevelsSettings();

    @TestVisible
    private static final String DATETIME_SOQL_FORMAT = 'yyyy-MM-dd\'T\'HH:mm:ss\'Z\'';
    /** @description The query for the batch process to run on.*/
    private String query;

    /** @description The Object name that we are running the batch process on.*/
    private String sObjectName;

    /** @description The Ladder Levels to run on this object */
    private Map<String, List<Level__c>> mapLadderToLevels;

    /** @description The time that the batch started */
    private DateTime batchStartTime;

    /*********************************************************************************************************
    * @description The batch process constructor; creates opportunity query for all opportunities.
    */
    public LVL_LevelAssign_BATCH(String query, String sObjectName) {
        this.query = query;
        this.sObjectName = sObjectName;

        // get our map of Ladder Levels
        this.mapLadderToLevels = mapLadderToLevelsForObject(sObjectName);
    }

    /*********************************************************************************************************
    * @description Batch process start method.
    */
    public Database.QueryLocator start(Database.BatchableContext BC) {
        batchStartTime = DateTime.now();
        return Database.getQueryLocator(query);
    }

    /*********************************************************************************************************
    * @description Batch process execute method. Goes thru each object, and evaluates it against each
    * ladder, and only updates it if levels change.
    */
    public void execute(Database.BatchableContext BC, List<SObject> scope) {
        // track our objects to update
        Map<Id, SObject> recordsById = new Map<Id, SObject>();

        // track our Engagement Plans to create
        List<Engagement_Plan__c> newEngagementPlans = new List<Engagement_Plan__c>();
        List<Error__c> errorsCreatingEngagementPlans = new List<Error__c>();

        // for each of our objects
        for (SObject record : scope) {
            // for each of our Ladders
            for (String target : mapLadderToLevels.keySet()) {
                List<Level__c> listLvls = mapLadderToLevels.get(target);
                Id lvlIdPrev;
                // track whether or not a match was found
                Boolean matchedLvl = false;
                // note that we have try/catches around using the level fields, so we can provide useful errors if they are invalid

                // go thru each list of Levels finding where this object fits
                for (Level__c level : listLvls) {
                    if (lvlIdPrev == null) {
                        try {
                            lvlIdPrev = (Id)record.get(target);
                        } catch (Exception ex) {
                            throw new LevelException(String.format(System.Label.lvlErrorInvalidLookupField, new list<String>{target, level.Name}));
                        }
                    }
                    Decimal amt;
                    try {
                        amt = (Decimal)record.get(level.Source_Field__c);
                    } catch (Exception ex) {
                        throw new LevelException(String.format(System.Label.lvlErrorInvalidSourceField, new list<String>{level.Source_Field__c, level.Name}));
                    }
                    if (amt == null)
                        amt = 0;

                    if ((amt >= level.Minimum_Amount__c || level.Minimum_Amount__c == null) &&
                        (amt < level.Maximum_Amount__c || level.Maximum_Amount__c == null)) {

                        // record the new level
                        matchedLvl = true;
                        if (lvlIdPrev != level.Id) {

                            populatePreviousLevelField(record, level, lvlIdPrev);

                            try {
                                record.put(target, level.Id);
                            } catch (exception ex) {
                                throw new LevelException(String.format(System.Label.lvlErrorInvalidLookupField, new list<String>{target, level.Name}));
                            }

                            recordsById.put(record.Id, record);

                            // apply the Engagement Plan
                            if (level.Engagement_Plan_Template__c != null) {
                                Engagement_Plan__c engagementPlanFromLevel = engagementPlanFromLevel(level, record.Id);
                                if (engagementPlanFromLevel != null) {
                                    newEngagementPlans.add(engagementPlanFromLevel);
                                } else {
                                    errorsCreatingEngagementPlans.add(
                                        new Error__c(
                                            Datetime__c = System.now(),
                                            Context_Type__c = ERR_Handler_API.Context.LVL.name(),
                                            Error_Type__c = 'Batch Apex error',
                                            Full_Message__c = (System.Label.engagementPlanMissingField + ' ' + level.Target__c)
                                        )
                                    );
                                }
                            }
                        }
                        // done with this level.
                        break;
                    }

                } // levels
                // After looping through all levels in the current ladder if no match found but level set clear level
                if (!matchedLvl && lvlIdPrev != null) {
                    //Use previous field's level to find which Previous_Level_Field__c needs to be populated
                    Level__c previousLevel = (new Map<Id, Level__c>(listLvls)).get(lvlIdPrev);

                    populatePreviousLevelField(record, previousLevel, lvlIdPrev);

                    record.put(target, null);
                    recordsById.put(record.Id, record);
                }
            } // ladder
        } // scope

        update recordsById.values();
        if (!newEngagementPlans.isEmpty()) {
            insert newEngagementPlans;
        }
        if (!errorsCreatingEngagementPlans.isEmpty()) {
            insert errorsCreatingEngagementPlans;
        }
    }

    /*******************************************************************************************************
    * @description Creates an Engagement Plan based on a Level record.
    * Attempts to find the engagement plan lookup field based on the level's target field
    * it could be either a standard object that requires us to add a namespace prefix and custom field suffix
    * e.g. Account -> npsp__Account__c, Contact -> npsp__Contact__c
    * or a standard object added by a user with no prefix that requires us to add a custom feild suffix
    * e.g. Case -> Case__c
    * or a custom object name without namespace prefix and with suffix already appended
    * e.g. Custom_Object__c -> Custom_Object__c
    * @param level The level used to create the Engagement Plan
    * @param target The Id of object to relate the Engagement Plan to
    * @return Engagement_Plan__c The Engagement Plan
    */
    private Engagement_Plan__c engagementPlanFromLevel(Level__c level, Id target) {
        Engagement_Plan__c plan = new Engagement_Plan__c(Engagement_Plan_Template__c = level.Engagement_Plan_Template__c);

        String engagementPlanPrefixed = UTIL_Namespace.StrTokenNSPrefix('Engagement_Plan__c');
        String targetFieldPrefixedAndSuffixed = UTIL_Namespace.StrTokenNSPrefix(level.Target__c + '__c');
        String targetFieldSuffixed = level.Target__c + '__c';

        if (UTIL_Describe.isValidField(engagementPlanPrefixed, targetFieldPrefixedAndSuffixed)) {
            plan.put(targetFieldPrefixedAndSuffixed, target);

        } else if (UTIL_Describe.isValidField(engagementPlanPrefixed, targetFieldSuffixed)) {
            plan.put(targetFieldSuffixed, target);

        } else if (UTIL_Describe.isValidField(engagementPlanPrefixed, level.Target__c)) {
            plan.put(level.Target__c, target);

        } else {
            //no matching field found, can't create an engagement plan
            return null;
        }
        return plan;
    }

    /*******************************************************************************************************
    * @description Populates SObject's Previous Level field with a level previously stored in the Level Field
    * @param record SObject
    * @param level The level used to find out the SObject's Previous Level Field
    * @param prevLevelId An Id of a level previously specified in the Level Field
    * @return void
    */
    private void populatePreviousLevelField(SObject record, Level__c level, Id prevLevelId) {
        if (level == null || level.Previous_Level_Field__c == null) {
            return;
        }

        try {
            record.put(level.Previous_Level_Field__c, prevLevelId);

        } catch(Exception ex) {
            throw new LevelException(
                String.format(
                    System.Label.lvlErrorInvalidLookupField,
                    new List<String>{ level.Previous_Level_Field__c, level.Name }
                )
            );
        }
    }

    private class LevelException extends Exception {}

    /*********************************************************************************************************
    * @description Batch process finish method, stores last job start time for accounts and contacts
    */
    public void finish(Database.BatchableContext context) {
        if (jobCompleted(context.getJobId())) {
            if (sObjectName == String.valueOf(Account.SObjectType)) {
                levelsSettings.LastJobStartTimeAccount__c = batchStartTime;
                upsert levelsSettings;
            } else if (sObjectName == String.valueOf(Contact.SObjectType)) {
                levelsSettings.LastJobStartTimeContact__c = batchStartTime;
                upsert levelsSettings;
            }
        }
    }

    /*********************************************************************************************************
    * @description Checks completed status of job for given Id
    * @returns Boolean true if job has a status of Completed
    */
    private Boolean jobCompleted(Id jobId) {
        AsyncApexJob job = [SELECT Status FROM AsyncApexJob WHERE Id = :jobId];
        return job.Status == 'Completed';
    }

    /*********************************************************************************************************
    * @description For the given object, return a map from it's different Ladders (Level_Field__c), to the
    * appropriate Levels for that Ladder. The levels are stored in increasing order for Minimum Amount.
    * @param sObjectName The object to get the ladder levels for
    * @return map<String, list<Level__c>> The map of Ladder Levels for the object
    */
    public static map<String, list<Level__c>> mapLadderToLevelsForObject(String sObjectName) {
        // get all our levels for this object type
        List<Level__c> listAllLvls = [
            SELECT
                Id, Name, Target__c, Source_Field__c, Level_Field__c,
                Previous_Level_Field__c, Active__c, Minimum_Amount__c,
                Maximum_Amount__c, Engagement_Plan_Template__c
            FROM Level__c
            WHERE Target__c = :sObjectName AND Active__c = true
            ORDER BY Level_Field__c ASC, Minimum_Amount__c ASC NULLS FIRST
        ];

        // create our map to store the list of Levels per Ladder
        Map<String, List<Level__c>> mapLadderToLvls = new Map<String, List<Level__c>>();

        for (Level__c lvl : listAllLvls) {
            String ladder = lvl.Level_Field__c;
            List<Level__c> listLvls = mapLadderToLvls.get(ladder);
            if (listLvls == null) {
                listLvls = new List<Level__c>();
                mapLadderToLvls.put(ladder, listLvls);
            }
            listLvls.add(lvl);
        }

        // we now have a map from Ladder to its list of Levels
        return mapLadderToLvls;
    }

    /*********************************************************************************************************
    * @description Query the Level object and return a list of Ladder records for each SObject type with levels
    * @return List<Ladder> ladders for each SObject type with levels
    */
    public static List<Ladder> getLadders() {
        List<Level__c> levels = [
            SELECT Id, Target__c, Source_Field__c, Level_Field__c,
                Previous_Level_Field__c, Active__c, LastModifiedDate
            FROM Level__c
            WHERE Active__c = true
            ORDER BY Target__c, Level_Field__c];

        List<Ladder> ladders = new List<Ladder>();

        Map<String,Ladder> ladderByTarget = new Map<String,Ladder>();
        for (Level__c level : levels) {
            if (!ladderByTarget.containsKey(level.Target__c)) {
                ladderByTarget.put(level.Target__c, new Ladder(level.Target__c));
            }
            ladderByTarget.get(level.Target__c).addLevel(level);
        }

        return ladderByTarget.values();
    }

    /*********************************************************************************************************
    * @description Stores all the Level__c records for a target SObject. One Ladder should only contain Level
    * records related to a single SObject (e.g. Account, Contact, etc.)
    */
    public class Ladder {
        public String target;
        private Set<String> queryFields = new Set<String>();
        private Set<String> sourceFields = new Set<String>();
        private DateTime mostRecentLastModifiedDate;
        private Boolean targetIsAccount {
            get {
                return target == String.valueOf(Account.SObjectType);
            }
        }

        private Boolean targetIsContact {
            get {
                return target == String.valueOf(Contact.SObjectType);
            }
        }

        /*********************************************************************************************************
        * @description Constructor
        */
        public Ladder(String target) {
            this.target = target;
        }

        /*********************************************************************************************************
        * @description Add a level to the ladder, caching query fields, source fields and the most recent
        * LastModifiedDate of all the levels in the ladder
        */
        public Ladder addLevel(Level__c level) {
            addQueryFields(level);

            sourceFields.add(level.Source_Field__c);

            if (mostRecentLastModifiedDate == null || mostRecentLastModifiedDate < level.LastModifiedDate) {
                mostRecentLastModifiedDate = level.LastModifiedDate;
            }

            return this;
        }

        /*********************************************************************************************************
        * @description Builds query to get object data need to calculate and assign levels
        * @returns SOQL string for querying SObjects for level calculation
        */
        public String buildQuery() {
            String soqlQuery = 'SELECT Id';
            for (String fieldName : queryFields) {
                soqlQuery += ', ' + fieldName;
            }
            soqlQuery += ' FROM ' + target + buildFilter();
            return soqlQuery;
        }

        /*********************************************************************************************************
        * @description Adds fields from Level that need to be queried
        */
        private void addQueryFields(Level__c level) {
            queryFields.add(level.Source_Field__c);
            queryFields.add(level.Level_Field__c);
            if (!String.isEmpty(level.Previous_Level_Field__c)) {
                queryFields.add(level.Previous_Level_Field__c);
            }
        }

        /*********************************************************************************************************
        * @description Builds query to calulate level for the target object with filter if necessary
        * @returns SOQL string
        */
        private String buildFilter() {
            final String WHERE_CLAUSE = ' WHERE SystemModStamp >= {0}';
            if (!shouldBuildFilter()) {
                return '';
            }

            DateTime datetimeToFilter;
            if (targetIsAccount) {
                datetimeToFilter = levelsSettings.LastJobStartTimeAccount__c;
            } else if (targetIsContact) {
                datetimeToFilter = levelsSettings.LastJobStartTimeContact__c;
            } else {
                return '';
            }

            String formattedDateTime = datetimeToFilter.formatGMT(DATETIME_SOQL_FORMAT);
            return String.format(WHERE_CLAUSE, new List<String>{formattedDateTime});
        }

        /*********************************************************************************************************
        * @description Determines if SystemModStamp filter should be built. Filter is NOT added target is not
        * an Account or Contact, if a level has been update since running the last job, or if
        * a source field is a formula
        * @returns Boolean for whether filter should be built
        */
        private Boolean shouldBuildFilter() {
            if (!targetIsAccount && !targetIsContact) {
                return false;
            } else if (targetIsAccount && (levelsSettings.LastJobStartTimeAccount__c == null || levelsSettings.LastJobStartTimeAccount__c < mostRecentLastModifiedDate )) {
                return false;
            } else if (targetIsContact && (levelsSettings.LastJobStartTimeContact__c == null || levelsSettings.LastJobStartTimeContact__c < mostRecentLastModifiedDate )) {
                return false;
            } else if (isAnySourceFieldAFormula()) {
                return false;
            } else {
                return true;
            }
        }

        /*********************************************************************************************************
        * @description Determines if any source field is a formula field
        * @returns Boolean true if any source field is a formula, otherwise false
        */
        private Boolean isAnySourceFieldAFormula() {
            for (String field : sourceFields) {
                if (UTIL_Describe.getFieldDescribe(target, field).isCalculated()) {
                    return true;
                }
            }
            return false;
         }
    }
}