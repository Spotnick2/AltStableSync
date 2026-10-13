------------------------------------------------------------
-- flavour_fixture.lua - a saved AltStableSync store for the A42 test (#11)
--
-- A valid schema-9 AltStableSyncDB and AltStableSyncChar, as written on build
-- 70245 (WOW_PROJECT_ID 1). Generated once through the real code (a load,
-- a save over it, a conflict copy, a tombstone, a manual backup, a pinned
-- operation, the minimap settings), then frozen here. FlavourFixture()
-- returns fresh copies each call.
------------------------------------------------------------

function FlavourFixture()
    local DB = {
        backups = {
            ["Player-70-MAIN"] = {
                firstSeen = {
                    actions = {
                        [1] = {
                            id = 9472,
                            kind = "spell",
                        },
                        [2] = {
                            id = 2050,
                            kind = "spell",
                        },
                        [3] = {
                            id = 5512,
                            kind = "item",
                        },
                        [4] = {
                            body = "/cast Power Word: Shield",
                            icon = 134400,
                            index = 121,
                            kind = "macro",
                            name = "Shield",
                            scope = "char",
                        },
                        [5] = {
                            id = 2050,
                            kind = "spell",
                        },
                        [6] = false,
                        [7] = false,
                        [8] = false,
                        [9] = false,
                        [10] = false,
                        [11] = false,
                        [12] = false,
                        [13] = false,
                        [14] = false,
                        [15] = false,
                        [16] = false,
                        [17] = false,
                        [18] = false,
                        [19] = false,
                        [20] = false,
                        [21] = false,
                        [22] = false,
                        [23] = false,
                        [24] = false,
                        [25] = false,
                        [26] = false,
                        [27] = false,
                        [28] = false,
                        [29] = false,
                        [30] = false,
                        [31] = false,
                        [32] = false,
                        [33] = false,
                        [34] = false,
                        [35] = false,
                        [36] = false,
                        [37] = false,
                        [38] = false,
                        [39] = false,
                        [40] = false,
                        [41] = false,
                        [42] = false,
                        [43] = false,
                        [44] = false,
                        [45] = false,
                        [46] = false,
                        [47] = false,
                        [48] = false,
                        [49] = false,
                        [50] = false,
                        [51] = false,
                        [52] = false,
                        [53] = false,
                        [54] = false,
                        [55] = false,
                        [56] = false,
                        [57] = false,
                        [58] = false,
                        [59] = false,
                        [60] = false,
                        [61] = false,
                        [62] = false,
                        [63] = false,
                        [64] = false,
                        [65] = false,
                        [66] = false,
                        [67] = false,
                        [68] = false,
                        [69] = false,
                        [70] = false,
                        [71] = false,
                        [72] = false,
                        [73] = false,
                        [74] = false,
                        [75] = false,
                        [76] = false,
                        [77] = false,
                        [78] = false,
                        [79] = false,
                        [80] = false,
                        [81] = false,
                        [82] = false,
                        [83] = false,
                        [84] = false,
                        [85] = false,
                        [86] = false,
                        [87] = false,
                        [88] = false,
                        [89] = false,
                        [90] = false,
                        [91] = false,
                        [92] = false,
                        [93] = false,
                        [94] = false,
                        [95] = false,
                        [96] = false,
                        [97] = false,
                        [98] = false,
                        [99] = false,
                        [100] = false,
                        [101] = false,
                        [102] = false,
                        [103] = false,
                        [104] = false,
                        [105] = false,
                        [106] = false,
                        [107] = false,
                        [108] = false,
                        [109] = false,
                        [110] = false,
                        [111] = false,
                        [112] = false,
                        [113] = false,
                        [114] = false,
                        [115] = false,
                        [116] = false,
                        [117] = false,
                        [118] = false,
                        [119] = false,
                        [120] = false,
                        [145] = false,
                        [146] = false,
                        [147] = false,
                        [148] = false,
                        [149] = false,
                        [150] = false,
                        [151] = false,
                        [152] = false,
                        [153] = false,
                        [154] = false,
                        [155] = false,
                        [156] = false,
                        [157] = false,
                        [158] = false,
                        [159] = false,
                        [160] = false,
                        [161] = false,
                        [162] = false,
                        [163] = false,
                        [164] = false,
                        [165] = false,
                        [166] = false,
                        [167] = false,
                        [168] = false,
                        [169] = false,
                        [170] = false,
                        [171] = false,
                        [172] = false,
                        [173] = false,
                        [174] = false,
                        [175] = false,
                        [176] = false,
                        [177] = false,
                        [178] = false,
                        [179] = false,
                        [180] = false,
                    },
                    at = 1760000000,
                    characterBindings = true,
                    createdMacros = {
                    },
                    keys = {
                        ["1"] = "ACTIONBUTTON1",
                        ["2"] = "ACTIONBUTTON2",
                    },
                    reason = "Manual",
                },
                operation = {
                    op = {
                        id = "loadout-a45904317cf0-1",
                        kind = "load",
                        name = "Everyday",
                        version = "v",
                    },
                    snapshot = {
                        actions = {
                        },
                        at = 5,
                        createdMacros = {
                        },
                        keys = {
                        },
                        reason = "load X",
                    },
                },
                ring = {
                    [1] = {
                        actions = {
                            [1] = {
                                id = 9472,
                                kind = "spell",
                            },
                            [2] = {
                                id = 2050,
                                kind = "spell",
                            },
                            [3] = {
                                id = 5512,
                                kind = "item",
                            },
                            [4] = {
                                body = "/cast Power Word: Shield",
                                icon = 134400,
                                index = 121,
                                kind = "macro",
                                name = "Shield",
                                scope = "char",
                            },
                            [5] = {
                                id = 2050,
                                kind = "spell",
                            },
                            [6] = false,
                            [7] = false,
                            [8] = false,
                            [9] = false,
                            [10] = false,
                            [11] = false,
                            [12] = false,
                            [13] = false,
                            [14] = false,
                            [15] = false,
                            [16] = false,
                            [17] = false,
                            [18] = false,
                            [19] = false,
                            [20] = false,
                            [21] = false,
                            [22] = false,
                            [23] = false,
                            [24] = false,
                            [25] = false,
                            [26] = false,
                            [27] = false,
                            [28] = false,
                            [29] = false,
                            [30] = false,
                            [31] = false,
                            [32] = false,
                            [33] = false,
                            [34] = false,
                            [35] = false,
                            [36] = false,
                            [37] = false,
                            [38] = false,
                            [39] = false,
                            [40] = false,
                            [41] = false,
                            [42] = false,
                            [43] = false,
                            [44] = false,
                            [45] = false,
                            [46] = false,
                            [47] = false,
                            [48] = false,
                            [49] = false,
                            [50] = false,
                            [51] = false,
                            [52] = false,
                            [53] = false,
                            [54] = false,
                            [55] = false,
                            [56] = false,
                            [57] = false,
                            [58] = false,
                            [59] = false,
                            [60] = false,
                            [61] = false,
                            [62] = false,
                            [63] = false,
                            [64] = false,
                            [65] = false,
                            [66] = false,
                            [67] = false,
                            [68] = false,
                            [69] = false,
                            [70] = false,
                            [71] = false,
                            [72] = false,
                            [73] = false,
                            [74] = false,
                            [75] = false,
                            [76] = false,
                            [77] = false,
                            [78] = false,
                            [79] = false,
                            [80] = false,
                            [81] = false,
                            [82] = false,
                            [83] = false,
                            [84] = false,
                            [85] = false,
                            [86] = false,
                            [87] = false,
                            [88] = false,
                            [89] = false,
                            [90] = false,
                            [91] = false,
                            [92] = false,
                            [93] = false,
                            [94] = false,
                            [95] = false,
                            [96] = false,
                            [97] = false,
                            [98] = false,
                            [99] = false,
                            [100] = false,
                            [101] = false,
                            [102] = false,
                            [103] = false,
                            [104] = false,
                            [105] = false,
                            [106] = false,
                            [107] = false,
                            [108] = false,
                            [109] = false,
                            [110] = false,
                            [111] = false,
                            [112] = false,
                            [113] = false,
                            [114] = false,
                            [115] = false,
                            [116] = false,
                            [117] = false,
                            [118] = false,
                            [119] = false,
                            [120] = false,
                            [145] = false,
                            [146] = false,
                            [147] = false,
                            [148] = false,
                            [149] = false,
                            [150] = false,
                            [151] = false,
                            [152] = false,
                            [153] = false,
                            [154] = false,
                            [155] = false,
                            [156] = false,
                            [157] = false,
                            [158] = false,
                            [159] = false,
                            [160] = false,
                            [161] = false,
                            [162] = false,
                            [163] = false,
                            [164] = false,
                            [165] = false,
                            [166] = false,
                            [167] = false,
                            [168] = false,
                            [169] = false,
                            [170] = false,
                            [171] = false,
                            [172] = false,
                            [173] = false,
                            [174] = false,
                            [175] = false,
                            [176] = false,
                            [177] = false,
                            [178] = false,
                            [179] = false,
                            [180] = false,
                        },
                        at = 1760000000,
                        characterBindings = true,
                        createdMacros = {
                        },
                        keys = {
                            ["1"] = "ACTIONBUTTON1",
                            ["2"] = "ACTIONBUTTON2",
                        },
                        reason = "Manual",
                    },
                },
            },
        },
        minimap = {
            angle = 200,
            hide = false,
        },
        presets = {
            ["loadout-a45904317cf0-1"] = {
                ancestors = {
                    [1] = "a45904317cf0:1",
                },
                category = "holy",
                class = "PRIEST",
                created = 1760000000,
                id = "loadout-a45904317cf0-1",
                kind = "loadout",
                modules = {
                    actions = {
                        [1] = {
                            class = true,
                            id = 9472,
                            kind = "spell",
                            name = "Flash Heal",
                            policy = "highest",
                        },
                        [2] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                        [3] = {
                            id = 5512,
                            kind = "item",
                        },
                        [4] = {
                            body = "/cast Power Word: Shield",
                            kind = "macro",
                            name = "Shield",
                            scope = "char",
                        },
                        [5] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                    },
                    bindings = {
                        ACTIONBUTTON1 = {
                            [1] = "1",
                        },
                        ACTIONBUTTON10 = {
                        },
                        ACTIONBUTTON11 = {
                        },
                        ACTIONBUTTON12 = {
                        },
                        ACTIONBUTTON2 = {
                            [1] = "2",
                        },
                        ACTIONBUTTON3 = {
                        },
                        ACTIONBUTTON4 = {
                        },
                        ACTIONBUTTON5 = {
                        },
                        ACTIONBUTTON6 = {
                        },
                        ACTIONBUTTON7 = {
                        },
                        ACTIONBUTTON8 = {
                        },
                        ACTIONBUTTON9 = {
                        },
                        BONUSACTIONBUTTON1 = {
                        },
                        BONUSACTIONBUTTON10 = {
                        },
                        BONUSACTIONBUTTON2 = {
                        },
                        BONUSACTIONBUTTON3 = {
                        },
                        BONUSACTIONBUTTON4 = {
                        },
                        BONUSACTIONBUTTON5 = {
                        },
                        BONUSACTIONBUTTON6 = {
                        },
                        BONUSACTIONBUTTON7 = {
                        },
                        BONUSACTIONBUTTON8 = {
                        },
                        BONUSACTIONBUTTON9 = {
                        },
                    },
                    cover = {
                        [1] = {
                            [1] = 1,
                            [2] = 120,
                        },
                        [2] = {
                            [1] = 145,
                            [2] = 180,
                        },
                    },
                    macros = {
                        Shield = {
                            body = "/cast Power Word: Shield",
                            icon = 134400,
                        },
                    },
                },
                name = "Everyday",
                parent = "a45904317cf0:1",
                previous = {
                    modules = {
                        actions = {
                            [1] = {
                                class = true,
                                id = 9472,
                                kind = "spell",
                                name = "Flash Heal",
                                policy = "highest",
                            },
                            [2] = {
                                class = true,
                                id = 2050,
                                kind = "spell",
                                name = "Lesser Heal",
                                policy = "highest",
                            },
                            [3] = {
                                id = 5512,
                                kind = "item",
                            },
                            [4] = {
                                body = "/cast Power Word: Shield",
                                kind = "macro",
                                name = "Shield",
                                scope = "char",
                            },
                        },
                        bindings = {
                            ACTIONBUTTON1 = {
                                [1] = "1",
                            },
                            ACTIONBUTTON10 = {
                            },
                            ACTIONBUTTON11 = {
                            },
                            ACTIONBUTTON12 = {
                            },
                            ACTIONBUTTON2 = {
                                [1] = "2",
                            },
                            ACTIONBUTTON3 = {
                            },
                            ACTIONBUTTON4 = {
                            },
                            ACTIONBUTTON5 = {
                            },
                            ACTIONBUTTON6 = {
                            },
                            ACTIONBUTTON7 = {
                            },
                            ACTIONBUTTON8 = {
                            },
                            ACTIONBUTTON9 = {
                            },
                            BONUSACTIONBUTTON1 = {
                            },
                            BONUSACTIONBUTTON10 = {
                            },
                            BONUSACTIONBUTTON2 = {
                            },
                            BONUSACTIONBUTTON3 = {
                            },
                            BONUSACTIONBUTTON4 = {
                            },
                            BONUSACTIONBUTTON5 = {
                            },
                            BONUSACTIONBUTTON6 = {
                            },
                            BONUSACTIONBUTTON7 = {
                            },
                            BONUSACTIONBUTTON8 = {
                            },
                            BONUSACTIONBUTTON9 = {
                            },
                        },
                        cover = {
                            [1] = {
                                [1] = 1,
                                [2] = 120,
                            },
                            [2] = {
                                [1] = 145,
                                [2] = 180,
                            },
                        },
                        macros = {
                            Shield = {
                                body = "/cast Power Word: Shield",
                                icon = 134400,
                            },
                        },
                    },
                    of = "a45904317cf0:2",
                    updated = 1760000000,
                },
                provenance = {
                    build = "70245",
                    sourceChar = "Karuzo-Elegia",
                },
                updated = 1760000000,
                version = "a45904317cf0:2",
            },
            ["loadout-a45904317cf0-3"] = {
                ancestors = {
                },
                category = "shadow",
                class = "PRIEST",
                created = 1760000000,
                id = "loadout-a45904317cf0-3",
                kind = "loadout",
                modules = {
                    actions = {
                        [1] = {
                            class = true,
                            id = 9472,
                            kind = "spell",
                            name = "Flash Heal",
                            policy = "highest",
                        },
                        [2] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                        [3] = {
                            id = 5512,
                            kind = "item",
                        },
                        [4] = {
                            body = "/cast Power Word: Shield",
                            kind = "macro",
                            name = "Shield",
                            scope = "char",
                        },
                        [5] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                    },
                    bindings = {
                        ACTIONBUTTON1 = {
                            [1] = "1",
                        },
                        ACTIONBUTTON10 = {
                        },
                        ACTIONBUTTON11 = {
                        },
                        ACTIONBUTTON12 = {
                        },
                        ACTIONBUTTON2 = {
                            [1] = "2",
                        },
                        ACTIONBUTTON3 = {
                        },
                        ACTIONBUTTON4 = {
                        },
                        ACTIONBUTTON5 = {
                        },
                        ACTIONBUTTON6 = {
                        },
                        ACTIONBUTTON7 = {
                        },
                        ACTIONBUTTON8 = {
                        },
                        ACTIONBUTTON9 = {
                        },
                        BONUSACTIONBUTTON1 = {
                        },
                        BONUSACTIONBUTTON10 = {
                        },
                        BONUSACTIONBUTTON2 = {
                        },
                        BONUSACTIONBUTTON3 = {
                        },
                        BONUSACTIONBUTTON4 = {
                        },
                        BONUSACTIONBUTTON5 = {
                        },
                        BONUSACTIONBUTTON6 = {
                        },
                        BONUSACTIONBUTTON7 = {
                        },
                        BONUSACTIONBUTTON8 = {
                        },
                        BONUSACTIONBUTTON9 = {
                        },
                    },
                    cover = {
                        [1] = {
                            [1] = 1,
                            [2] = 120,
                        },
                        [2] = {
                            [1] = 145,
                            [2] = 180,
                        },
                    },
                    macros = {
                        Shield = {
                            body = "/cast Power Word: Shield",
                            icon = 134400,
                        },
                    },
                },
                name = "Dots",
                updated = 1760000000,
                version = "a45904317cf0:3",
            },
            ["loadout-a45904317cf0-3~eeeeeeeeeeee:4"] = {
                ancestors = {
                },
                category = "shadow",
                class = "PRIEST",
                conflict = {
                    from = "Other-Elegia",
                    name = "Dots",
                    of = "loadout-a45904317cf0-3",
                },
                created = 1760000000,
                id = "loadout-a45904317cf0-3~eeeeeeeeeeee:4",
                kind = "loadout",
                modules = {
                    actions = {
                        [1] = {
                            class = true,
                            id = 9472,
                            kind = "spell",
                            name = "Flash Heal",
                            policy = "highest",
                        },
                        [2] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                        [3] = {
                            id = 5512,
                            kind = "item",
                        },
                        [4] = {
                            body = "/cast Power Word: Shield",
                            kind = "macro",
                            name = "Shield",
                            scope = "char",
                        },
                        [5] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                    },
                    bindings = {
                        ACTIONBUTTON1 = {
                            [1] = "1",
                        },
                        ACTIONBUTTON10 = {
                        },
                        ACTIONBUTTON11 = {
                        },
                        ACTIONBUTTON12 = {
                        },
                        ACTIONBUTTON2 = {
                            [1] = "2",
                        },
                        ACTIONBUTTON3 = {
                        },
                        ACTIONBUTTON4 = {
                        },
                        ACTIONBUTTON5 = {
                        },
                        ACTIONBUTTON6 = {
                        },
                        ACTIONBUTTON7 = {
                        },
                        ACTIONBUTTON8 = {
                        },
                        ACTIONBUTTON9 = {
                        },
                        BONUSACTIONBUTTON1 = {
                        },
                        BONUSACTIONBUTTON10 = {
                        },
                        BONUSACTIONBUTTON2 = {
                        },
                        BONUSACTIONBUTTON3 = {
                        },
                        BONUSACTIONBUTTON4 = {
                        },
                        BONUSACTIONBUTTON5 = {
                        },
                        BONUSACTIONBUTTON6 = {
                        },
                        BONUSACTIONBUTTON7 = {
                        },
                        BONUSACTIONBUTTON8 = {
                        },
                        BONUSACTIONBUTTON9 = {
                        },
                    },
                    cover = {
                        [1] = {
                            [1] = 1,
                            [2] = 120,
                        },
                        [2] = {
                            [1] = 145,
                            [2] = 180,
                        },
                    },
                    macros = {
                        Shield = {
                            body = "/cast Power Word: Shield",
                            icon = 134400,
                        },
                    },
                },
                name = "Dots (from Other-Elegia)",
                parent = "eeeeeeeeeeee:3",
                updated = 1760000000,
                version = "eeeeeeeeeeee:4",
            },
            ["loadout-a45904317cf0-4"] = {
                ancestors = {
                    [1] = "a45904317cf0:4",
                },
                category = "general",
                class = "PRIEST",
                created = 1760000000,
                deleted = true,
                id = "loadout-a45904317cf0-4",
                kind = "loadout",
                name = "Old",
                parent = "a45904317cf0:4",
                updated = 1760000000,
                version = "a45904317cf0:5",
            },
        },
        schema = 9,
    }
    local CHAR = {
        interrupted = {
            at = 1,
            id = "loadout-a45904317cf0-1",
            version = "v",
            why = "combat",
        },
        loaded = {
            loadout = {
                after = {
                    actions = {
                        [1] = {
                            class = true,
                            id = 9472,
                            kind = "spell",
                            name = "Flash Heal",
                            policy = "highest",
                        },
                        [2] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                        [3] = {
                            id = 5512,
                            kind = "item",
                        },
                        [4] = {
                            body = "/cast Power Word: Shield",
                            icon = 134400,
                            kind = "macro",
                            name = "Shield",
                            scope = "char",
                        },
                        [5] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                    },
                    bindings = {
                        ACTIONBUTTON1 = {
                            [1] = "1",
                        },
                        ACTIONBUTTON10 = {
                        },
                        ACTIONBUTTON11 = {
                        },
                        ACTIONBUTTON12 = {
                        },
                        ACTIONBUTTON2 = {
                            [1] = "2",
                        },
                        ACTIONBUTTON3 = {
                        },
                        ACTIONBUTTON4 = {
                        },
                        ACTIONBUTTON5 = {
                        },
                        ACTIONBUTTON6 = {
                        },
                        ACTIONBUTTON7 = {
                        },
                        ACTIONBUTTON8 = {
                        },
                        ACTIONBUTTON9 = {
                        },
                        BONUSACTIONBUTTON1 = {
                        },
                        BONUSACTIONBUTTON10 = {
                        },
                        BONUSACTIONBUTTON2 = {
                        },
                        BONUSACTIONBUTTON3 = {
                        },
                        BONUSACTIONBUTTON4 = {
                        },
                        BONUSACTIONBUTTON5 = {
                        },
                        BONUSACTIONBUTTON6 = {
                        },
                        BONUSACTIONBUTTON7 = {
                        },
                        BONUSACTIONBUTTON8 = {
                        },
                        BONUSACTIONBUTTON9 = {
                        },
                    },
                    cover = {
                        [1] = {
                            [1] = 1,
                            [2] = 120,
                        },
                        [2] = {
                            [1] = 145,
                            [2] = 180,
                        },
                    },
                    macros = {
                        Shield = {
                            body = "/cast Power Word: Shield",
                            icon = 134400,
                        },
                    },
                },
                baseline = {
                    actions = {
                        [1] = {
                            class = true,
                            id = 9472,
                            kind = "spell",
                            name = "Flash Heal",
                            policy = "highest",
                        },
                        [2] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                        [3] = {
                            id = 5512,
                            kind = "item",
                        },
                        [4] = {
                            body = "/cast Power Word: Shield",
                            kind = "macro",
                            name = "Shield",
                            scope = "char",
                        },
                        [5] = {
                            class = true,
                            id = 2050,
                            kind = "spell",
                            name = "Lesser Heal",
                            policy = "highest",
                        },
                    },
                    bindings = {
                        ACTIONBUTTON1 = {
                            [1] = "1",
                        },
                        ACTIONBUTTON10 = {
                        },
                        ACTIONBUTTON11 = {
                        },
                        ACTIONBUTTON12 = {
                        },
                        ACTIONBUTTON2 = {
                            [1] = "2",
                        },
                        ACTIONBUTTON3 = {
                        },
                        ACTIONBUTTON4 = {
                        },
                        ACTIONBUTTON5 = {
                        },
                        ACTIONBUTTON6 = {
                        },
                        ACTIONBUTTON7 = {
                        },
                        ACTIONBUTTON8 = {
                        },
                        ACTIONBUTTON9 = {
                        },
                        BONUSACTIONBUTTON1 = {
                        },
                        BONUSACTIONBUTTON10 = {
                        },
                        BONUSACTIONBUTTON2 = {
                        },
                        BONUSACTIONBUTTON3 = {
                        },
                        BONUSACTIONBUTTON4 = {
                        },
                        BONUSACTIONBUTTON5 = {
                        },
                        BONUSACTIONBUTTON6 = {
                        },
                        BONUSACTIONBUTTON7 = {
                        },
                        BONUSACTIONBUTTON8 = {
                        },
                        BONUSACTIONBUTTON9 = {
                        },
                    },
                    cover = {
                        [1] = {
                            [1] = 1,
                            [2] = 120,
                        },
                        [2] = {
                            [1] = 145,
                            [2] = 180,
                        },
                    },
                    macros = {
                        Shield = {
                            body = "/cast Power Word: Shield",
                            icon = 134400,
                        },
                    },
                },
                id = "loadout-a45904317cf0-1",
                unavailable = {
                },
                version = "a45904317cf0:2",
            },
        },
        schema = 9,
    }
    return DB, CHAR
end
