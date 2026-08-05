import QtQuick 2.5
import QtQuick.Controls 2.0
import QtQuick.Layouts 1.2

import "js/utils.mjs" as Utils

Item {
    id: root
    property var workshopDirs
    property var globalConfigPath
    property string filterStr: ""
    property int sortMode: Common.SortMode.Id
    property bool sortReverse: false
    // Free-text search over title / workshop id / tags. Empty means "no search".
    property string searchStr: ""
    property bool enabled: true

    property var initItemOp: null
    property var _initItemOp: Boolean(initItemOp) ? initItemOp : function(){ }
    property var readfile: null 
    property var _readfile: Boolean(readfile) ? readfile : function(){ return Promise.reject("read file func not available"); }

    signal modelStartSync
    signal modelRefreshed

    readonly property ListModel model: ListModel {
        function assignModel(index, value) {
            // setProperty, rather than mutating the object handed back by get(),
            // is what reliably notifies the delegates - so the bookmark icon in
            // the grid changes the instant it is clicked instead of only after
            // the next rescan.
            for(const key in value) this.setProperty(index, key, value[key]);
            const workshopid = this.get(index).workshopid;
            new Promise((resolve, reject) => {
                const model = folderWorker.model;
                for(let i=0;i<model.length;i++) {
                    if(model[i].workshopid === workshopid) {
                        Object.assign(model[i], value);
                        resolve();
                    }
                }
                reject();
            });
        }
    }

    property int countNoFilter: 0

    property var playlists: {}
    property var folderModels: []

    function loadItemFromJson(text, el) {
        const project = Utils.parseJson(text);    
        if(project !== null) {
            if("title" in project)
                el.title = project.title;
            if("preview" in project && project.preview)
                el.preview = project.preview;
            if("file" in project)
                el.file = project.file;
            if("type" in project)
                el.type = project.type.toLowerCase();
            if("contentrating" in project)
                el.contentrating = project.contentrating;
            if("tags" in project) {
                el.tags = project.tags.map(el => Object({key: el}));
            }
        }
    }

    function loadPlaylists() {
        // reset playlists property
        root.playlists = {};
    
        return root._readfile(Common.urlNative(globalConfigPath)).then(value => {
            var jsonData = JSON.parse(value);

            // refreshing entries in the filter model is not thread safe, so we need to lock it
            var filterModel = Common.filterModel;
            return filterModel.lock.lock().then(() => {
                // remove playlists from the filterModel
                var selectedPlaylists = new Set();
                for(var i =0; i < filterModel.count; i++) {
                    var el = filterModel.get(i);
                    if(el.type == "playlist") {
                        if(el.def) { selectedPlaylists.add(el.key); }
                        filterModel.remove(i);
                        i--;
                    }
                }

                jsonData.steamuser.general.playlists.forEach(function(el) {
                    // we're going to be using paths to match wallpapers to playlists, but the paths in the config will start with a Windows-style drive letter
                    // so we need to convert them to file:// URLs. In addition it appears that the paths are truncated to 110 chars elsewhere so we will do the same
                    // so that they can match later
                    root.playlists[el.name] = new Set(el.items.map(el => "file://" + el.substring(2).replace(/\/[^\/]*$/, "").substring(0,110))); 
                    // add the playlist to the filter model preserving it's previous selection status
                    filterModel.append({type: "playlist", key: el.name, text: el.name, def: selectedPlaylists.has(el.name) ? 1 : 0});                    
                });
            })
            .then(() => { filterModel.lock.release() })
            .catch(() => { filterModel.lock.release() });
        }).catch(reason => console.error("PlaylistLoadError " + reason.lineNumber + " -- " + reason.type + reason.message));
    }

    // Case-insensitive substring match against the wallpaper's title, its
    // workshop id, and its tags. `needle` is expected pre-trimmed/lowercased.
    function matchesSearch(el, needle) {
        if (String(el.title || "").toLowerCase().indexOf(needle) !== -1) return true;
        if (String(el.workshopid || "").toLowerCase().indexOf(needle) !== -1) return true;
        const tags = el.tags;
        if (tags) {
            for (var i = 0; i < tags.length; i++) {
                if (String(tags[i].key || "").toLowerCase().indexOf(needle) !== -1) return true;
            }
        }
        return false;
    }

    // Re-stamp the favourite flag on everything already loaded. Favourites are
    // fetched asynchronously and usually arrive after the library scan, so the
    // items built by initItemOp would otherwise all read as not-favourited.
    // Both the visible ListModel and the backing array need it: the array is
    // what the Favorite filter and the Favourites sort actually look at.
    function applyFavorites(isFavor) {
        const data = folderWorker.model;
        for(let i = 0; i < data.length; i++)
            data[i].favor = Boolean(isFavor(data[i].workshopid));

        const m = root.model;
        for(let j = 0; j < m.count; j++)
            m.setProperty(j, "favor", Boolean(isFavor(m.get(j).workshopid)));
    }

    // Is this workshop id already in the local library? Checks the unfiltered
    // backing array, not the visible model, so filters and search do not make
    // an installed wallpaper look missing.
    function hasWorkshopId(id) {
        const data = folderWorker.model;
        for(let i = 0; i < data.length; i++)
            if(data[i].workshopid === id) return true;
        return false;
    }

    function genSortCmp(mode) {
        const base = (function() {
            switch (mode) {
              case Common.SortMode.Modified:
                // Newest first by default; the reverse toggle gives oldest first.
                return function(a, b) {
                    return -((a.modified || 0) - (b.modified || 0));
                }
              case Common.SortMode.Name:
                return function(a, b) {
                    return String(a.title || "").localeCompare(String(b.title || ""),
                                                               undefined, { sensitivity: "base", numeric: true });
                }
              case Common.SortMode.Type:
                // Group by kind (scene/video/web), then by name inside each group.
                return function(a, b) {
                    const ta = String(a.type || ""), tb = String(b.type || "");
                    if (ta !== tb) return ta < tb ? -1 : 1;
                    return String(a.title || "").localeCompare(String(b.title || ""),
                                                               undefined, { sensitivity: "base", numeric: true });
                }
              case Common.SortMode.Favorite:
                return function(a, b) {
                    const fa = a.favor ? 0 : 1, fb = b.favor ? 0 : 1;
                    if (fa !== fb) return fa - fb;
                    return String(a.title || "").localeCompare(String(b.title || ""),
                                                               undefined, { sensitivity: "base", numeric: true });
                }
              case Common.SortMode.Id:
              default:
                return function(a, b) {
                    return a.workshopid < b.workshopid ? -1 : 1;
                };
            }
        })();

        if (!root.sortReverse) return base;
        return function(a, b) { return -base(a, b); };
    }

    Item {
        id: folderWorker

        // array
        property var folderMapModel: new Map()
        property var model: []

        function loadModel(path, data) {
            this.folderMapModel.set(path, data);
            this.model = [];
            this.folderMapModel.forEach((value, key) => {
                this.model.push(...value);
            });
            return filterToList(root.model, root.filterStr, this.model);
        }
        function filterToList(listModel, filterStr, data) {
            const filterValues = Common.filterModel.getValueArray(filterStr);
            const filterstr = Common.filterModel.map((el, index) => {
                    return {
                        type: el.type,
                        key: el.key,
                        value: filterValues[index]
                    };
                });
            root.modelStartSync();
            const needle = String(root.searchStr || "").trim().toLowerCase();
            return new Promise((resolve, reject) => {
                const filter = Common.filterModel.genFilter(filterstr);
                const model = listModel;
                data.sort(genSortCmp(sortMode));
                model.clear();
                data.forEach(function(el) {
                    if(!filter(el)) return;
                    if(needle && !root.matchesSearch(el, needle)) return;
                    model.append(el);
                });
                resolve();
            }).then(() => {
                root.countNoFilter = this.model.length;
                root.modelRefreshed();
            });
        }
    }

    function refresh() {
        if(!root.enabled) return Promise.resolve(null);
        const p_list = [];

        return loadPlaylists().then(() => {
            this.workshopDirs.forEach(el => {
                const dirs = (Array.isArray(el) ? el : [el]).map(Common.urlNative);
                p_list.push(pyext.get_folder_list(
                    dirs[0],
                    { only_dir: true, fallbacks: dirs.slice(1) }
                ).then(res => {
                    if(!res) console.error(`folder not found: ${dirs[0]}`);
                    return res;
                }).catch(reason => console.error(reason)));
            });
            return new Promise((resolve, reject) => {
                Promise.all(p_list).then(values => {
                    return this.loadFolderLists(values);
                }).then(() => {
                    resolve();
                }).catch(reason => {
                    console.error(reason)
                    resolve();
                });
            });
        });
    }

    function loadFolderLists(folders) {
        const proxyModel = []
        folders.forEach(folder => {
            if(!folder) return Promise.resolve();
            // seems qml's "for" is a function
            const folder_dir = folder.folder;
            folder.items.forEach(el => {
                const v = Object.assign({}, Common.wpitem_template);
                v.workshopid = el.name;
                // use qurl to convert to file://
                v.path = Qt.resolvedUrl(folder_dir + '/' + el.name).toString();
                v.modified = el.mtime;
                root._initItemOp(v);
                proxyModel.push(v);
            });
            //if(proxyModel) console.error(`show the first: ${proxyModel[0].path}`)
        });
        return new Promise((resolve, reject) => {
            const plist = []
            proxyModel.forEach((el) => {
                // as no allSettled, catch any error
                const p = root._readfile(Common.urlNative(Common.getWpModelProjectPath(el))).then(value => {                    
                        el.playlists = [];
                        root.loadItemFromJson(value, el);
                        Object.keys(root.playlists).forEach((key) => {
                            const value = root.playlists[key];
                            if(value.has(el.path)) {       
                                if(!el.playlists.includes(key))
                                    el.playlists.push(Object({key: key}));
                            }
                        });
                    }).catch(reason => console.error(reason));
                plist.push(p);
            });
            const path = this.folder;
            Promise.all(plist).then(value => {
                folderWorker.loadModel(path, proxyModel).then(() => resolve());
            }).catch(reason => {
                console.error(reason);
                resolve();
            });
        });

    }
    Component.onCompleted: {
        this.filterStrChanged.connect(function() {
            if(root.enabled) {
                return folderWorker.filterToList(root.model, root.filterStr, folderWorker.model)
            }
            return Promise.resolve();
        });
        this.sortModeChanged.connect(this.filterStrChanged);
        this.sortReverseChanged.connect(this.filterStrChanged);
        this.searchStrChanged.connect(this.filterStrChanged);
        this.enabledChanged.connect(this.refresh.bind(this));

        const fc = this.readfile;
        this.readfileChanged.connect(function() {
            if(fc === root.readfile) return Promise.resolve();
            return root.refresh().then(() => { fc = root.readfile; });
        });
        return this.refresh();
    }

    // scan once
    Timer {
        running: true
        interval: 10000
        repeat: false   //run once
        onTriggered: {
            if(wpListModel.model.count === 0)
                return wpListModel.refresh();  //refresh to scan
            return Promise.resolve();
        }
    }

}
