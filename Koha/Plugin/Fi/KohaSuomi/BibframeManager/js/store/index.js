// Pinia Store for Bibframe Manager
const { defineStore } = Pinia;

export const useBibframeStore = defineStore('bibframe', {
    state: () => ({
        baseUri: 'http://urn.fi/URN:NBN:fi:bib:',
        recordId: '',
        outputFormat: 'turtle',
        saveToDatabase: false,
        entities: [],
        error: null,
        success: null,
        generatedOutput: null,
        allTriples: [],
        
        // Property suggestions for each entity type
        propertySuggestions: {
            work: [
                { label: 'creator', value: 'bffi:creator' },
                { label: 'preferredTitle', value: 'bffi:preferredTitle' },
                { label: 'formOfWork', value: 'bffi:formOfWork' },
                { label: 'subject', value: 'bffi:subject' },
                { label: 'genreForm', value: 'bffi:genreForm' },
                { label: 'intendedAudience', value: 'bffi:intendedAudience' },
                { label: 'medium', value: 'bffi:medium' },
                { label: 'musicalKey', value: 'bffi:musicalKey' },
                { label: 'temporalCoverage', value: 'bffi:temporalCoverage' },
                { label: 'place', value: 'bffi:place' }
            ],
            expression: [
                { label: 'title', value: 'bffi:title' },
                { label: 'language', value: 'bffi:language' },
                { label: 'edition', value: 'bffi:edition' },
                { label: 'contentType', value: 'bffi:contentType' },
                { label: 'contributor', value: 'bffi:contributor' },
                { label: 'note', value: 'bffi:note' },
                { label: 'tableOfContents', value: 'bffi:tableOfContents' },
                { label: 'languageNote', value: 'bffi:languageNote' },
                { label: 'date', value: 'bffi:date' }
            ],
            manifestation: [
                { label: 'isbn', value: 'bffi:isbn' },
                { label: 'issn', value: 'bffi:issn' },
                { label: 'publication', value: 'bffi:publication' },
                { label: 'extent', value: 'bffi:extent' },
                { label: 'mediaType', value: 'bffi:mediaType' },
                { label: 'carrierType', value: 'bffi:carrierType' },
                { label: 'electronicLocation', value: 'bffi:electronicLocation' },
                { label: 'identifiedBy', value: 'bffi:identifiedBy' },
                { label: 'seriesStatement', value: 'bffi:seriesStatement' },
                { label: 'physicalCharacteristic', value: 'bffi:physicalCharacteristic' }
            ],
            item: [
                { label: 'heldBy', value: 'bffi:heldBy' },
                { label: 'itemInformation', value: 'bffi:itemInformation' },
                { label: 'enumerationAndChronology', value: 'bffi:enumerationAndChronology' }
            ]
        }
    }),
    
    getters: {
        getPropertySuggestions: (state) => (entityType) => {
            return state.propertySuggestions[entityType] || [];
        },
        
        hasEntities: (state) => state.entities.length > 0,
        
        hasOutput: (state) => state.generatedOutput !== null
    },
    
    actions: {
        addEntity(type) {
            this.entities.push({
                type: type,
                uri: '',
                properties: [],
                relationships: []
            });
        },
        
        removeEntity(index) {
            this.entities.splice(index, 1);
        },
        
        addProperty(entityIndex) {
            this.entities[entityIndex].properties.push({
                predicate: '',
                customPredicate: '',
                object: '',
                objectType: 'literal'
            });
        },
        
        removeProperty(entityIndex, propIndex) {
            this.entities[entityIndex].properties.splice(propIndex, 1);
        },
        
        addRelationship(entityIndex) {
            this.entities[entityIndex].relationships.push({
                predicate: '',
                customPredicate: '',
                targetUri: ''
            });
        },
        
        removeRelationship(entityIndex, relIndex) {
            this.entities[entityIndex].relationships.splice(relIndex, 1);
        },
        
        addPropertySuggestion(entityType, propertyValue) {
            const entityIndex = this.entities.findIndex(e => e.type === entityType);
            if (entityIndex !== -1) {
                this.entities[entityIndex].properties.push({
                    predicate: propertyValue,
                    customPredicate: '',
                    object: '',
                    objectType: 'literal'
                });
            } else {
                this.success = `Please add a ${entityType} entity first`;
                setTimeout(() => { this.success = null; }, 2000);
            }
        },
        
        setError(message) {
            this.error = message;
        },
        
        clearError() {
            this.error = null;
        },
        
        setSuccess(message) {
            this.success = message;
        },
        
        clearSuccess() {
            this.success = null;
        },
        
        generateBibframe() {
            this.error = null;
            this.generatedOutput = null;
            this.allTriples = [];
            
            if (this.entities.length === 0) {
                this.error = 'Please add at least one entity';
                return;
            }
            
            if (!this.recordId) {
                this.error = 'Please provide a Record ID';
                return;
            }
            
            // Generate triples from entities
            const triples = [];
            
            this.entities.forEach(entity => {
                const subjectUri = entity.uri || `${this.baseUri}${this.recordId}/${entity.type}`;
                
                // Add rdf:type triple
                triples.push({
                    subject: subjectUri,
                    predicate: 'rdf:type',
                    object: `bffi:${entity.type.charAt(0).toUpperCase() + entity.type.slice(1)}`,
                    objectType: 'uri'
                });
                
                // Add properties
                entity.properties.forEach(prop => {
                    if (prop.object && (prop.predicate || prop.customPredicate)) {
                        triples.push({
                            subject: subjectUri,
                            predicate: prop.predicate === 'custom' ? prop.customPredicate : prop.predicate,
                            object: prop.object,
                            objectType: prop.objectType
                        });
                    }
                });
                
                // Add relationships
                entity.relationships.forEach(rel => {
                    if (rel.targetUri && (rel.predicate || rel.customPredicate)) {
                        triples.push({
                            subject: subjectUri,
                            predicate: rel.predicate === 'custom' ? rel.customPredicate : rel.predicate,
                            object: rel.targetUri,
                            objectType: 'uri'
                        });
                    }
                });
            });
            
            this.allTriples = triples.map((t, i) => ({ ...t, id: i }));
            
            // Format output based on selected format
            if (this.outputFormat === 'turtle') {
                this.generatedOutput = this.formatAsTurtle(triples);
            } else if (this.outputFormat === 'json-ld') {
                this.generatedOutput = this.formatAsJsonLd(triples);
            } else if (this.outputFormat === 'ntriples') {
                this.generatedOutput = this.formatAsNTriples(triples);
            } else {
                this.generatedOutput = JSON.stringify(triples, null, 2);
            }
            
            this.success = 'Bibframe record generated successfully!';
        },
        
        formatAsTurtle(triples) {
            let output = '@prefix bffi: <http://urn.fi/URN:NBN:fi:schema:bffi:> .\n';
            output += '@prefix bf: <http://id.loc.gov/ontologies/bibframe/> .\n';
            output += '@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .\n';
            output += '@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .\n\n';
            
            const groupedTriples = {};
            triples.forEach(t => {
                if (!groupedTriples[t.subject]) {
                    groupedTriples[t.subject] = [];
                }
                groupedTriples[t.subject].push(t);
            });
            
            Object.keys(groupedTriples).forEach(subject => {
                output += `<${subject}>\n`;
                groupedTriples[subject].forEach((t, i) => {
                    const obj = t.objectType === 'uri' ? `<${t.object}>` : `"${t.object}"`;
                    const ending = i === groupedTriples[subject].length - 1 ? ' .' : ' ;';
                    output += `    ${t.predicate} ${obj}${ending}\n`;
                });
                output += '\n';
            });
            
            return output;
        },
        
        formatAsJsonLd(triples) {
            const context = {
                "@context": {
                    "bffi": "http://urn.fi/URN:NBN:fi:schema:bffi:",
                    "bf": "http://id.loc.gov/ontologies/bibframe/",
                    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                }
            };
            
            const groupedTriples = {};
            
            triples.forEach(t => {
                if (!groupedTriples[t.subject]) {
                    groupedTriples[t.subject] = { "@id": t.subject };
                }
                const pred = t.predicate.replace('bffi:', '').replace('rdf:', '');
                groupedTriples[t.subject][pred] = t.objectType === 'uri' ? { "@id": t.object } : t.object;
            });
            
            context["@graph"] = Object.values(groupedTriples);
            
            return JSON.stringify(context, null, 2);
        },
        
        formatAsNTriples(triples) {
            let output = '';
            triples.forEach(t => {
                const obj = t.objectType === 'uri' ? `<${t.object}>` : `"${t.object}"`;
                output += `<${t.subject}> <${t.predicate}> ${obj} .\n`;
            });
            return output;
        },
        
        resetForm() {
            if (confirm('Are you sure you want to reset? All data will be lost.')) {
                this.entities = [];
                this.recordId = '';
                this.generatedOutput = null;
                this.allTriples = [];
                this.success = 'Form reset';
                this.generateRecordId();
            }
        },
        
        generateRecordId() {
            this.recordId = 'bffi-' + Math.random().toString(36).substr(2, 9);
        }
    }
});
